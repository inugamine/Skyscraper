//
//  TabGrouper.swift
//  Skyscraper
//
//  タブ一覧をオンデバイスLLM（Apple Intelligence / Foundation Models）に渡して、
//  話題ごとのグループへ自動で振り分ける。
//  処理は完全にオンデバイスで行われ、閲覧内容が外部へ送られることはない。
//
//  設計方針：グループ化は「表示層」だけで行う。TabManager.tabs の並び順には
//  一切手を付けず、タブID → グループ名の対応表（assignments）だけを持つ。
//  これにより ZStack 常時マウント・⌘1〜9 の番号選択などの既存挙動を壊さない。
//
//  言語まわりの注意：Foundation Models はプロンプトに非対応言語が混ざると
//  丸ごと拒否する。@ハンドルなどのローマ字ノイズが外国語と誤判定されがちなので、
//  「判定する文」と「モデルに送る文」を必ず同じ掃除（sanitize）を通した文にする。
//  ここが食い違うと、こちらの判定で通した行が Apple 側で弾かれ続ける。
//

import Foundation
import Combine
import WebKit
import NaturalLanguage
import FoundationModels

// モデルに出力させる構造（guided generation）。
// @Generable を付けると、モデルの出力がこの型に確実にデコードされる
@Generable
struct TabGroupingResult {
    @Guide(description: "タブのグループ分けの結果")
    var groups: [GroupedTabs]
}

@Generable
struct GroupedTabs {
    @Guide(description: "グループ名。短く簡潔に（例：ニュース、開発、買い物）。タブのタイトルと同じ言語で付ける")
    var name: String

    @Guide(description: "このグループに属するタブの番号（入力一覧で示された番号）")
    var tabNumbers: [Int]
}

@MainActor
final class TabGrouper: ObservableObject {
    // タブID → グループ名。載っていないタブは「グループ無し」扱い
    @Published var assignments: [UUID: String] = [:]

    // 手動で割り当てられたタブ（ピン留め）。
    // 自動再グループ化では一切上書きしない
    @Published private(set) var pinned: Set<UUID> = []

    // モデルが考え中か（再生成ボタンのスピナー表示用）
    @Published private(set) var isWorking = false

    // デバウンス待ちのタスク。キャンセルしてよいのはこっちだけ
    private var debounce: Task<Void, Never>?
    // 実行中・実行待ちの本体。絶対にキャンセルしない。
    // （respond を途中で殺すと FoundationModels が
    //  「Canceled state in response to PrewarmSession」を吐いて結果が捨てられる。
    //  後発の要求は前の実行の完了を待ってから順番に走る）
    private var running: Task<Void, Never>?

    // 一度でも Apple 側の言語判定に拒否されたら true。
    // 以降は最初から厳しい判定で候補を絞り、
    // 「失敗→やり直し」の無駄な一往復を毎回払わずに済む（再起動でリセット）
    private var preferStrictFilter = false

    // Apple Intelligence が使えるか。
    // 設定でオフ・モデル未ダウンロード・非対応機ではここが false になり、
    // グループ化は一切走らず従来のフラットな一覧のまま動く
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    // タブの増減・タイトル確定のたびに呼ぶ。
    // 2秒のデバウンスを挟み、連続変更では最後の一回だけ実行する。
    // 既にモデルが考え中の場合は、その完了を待ってから走る（キャンセルはしない）
    func scheduleRegroup(for tabs: [Tab]) {
        guard isAvailable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.enqueueRegroup(tabs: tabs, minimumTabs: 4)
        }
    }

    // 今すぐ組み直す（再生成ボタン用。デバウンス無し）。
    // clearingManual に true を渡すと手動割り当て（ピン留め）もご破算にして、
    // まっさらから組み直す
    func regroupNow(tabs: [Tab], clearingManual: Bool = false) {
        guard isAvailable else { return }
        debounce?.cancel()
        if clearingManual {
            pinned = []
        }
        // 手動実行は2枚から動く（押したのに無反応、を避ける）
        enqueueRegroup(tabs: tabs, minimumTabs: 2)
    }

    // 前の実行に連結して順番に走らせる。実行中の respond を途中で殺さない
    private func enqueueRegroup(tabs: [Tab], minimumTabs: Int) {
        let previous = running
        running = Task { [weak self] in
            await previous?.value
            await self?.regroup(tabs: tabs, minimumTabs: minimumTabs)
        }
    }

    // 手動でグループを割り当てる（nil なら「グループ無し」）。
    // 以降の自動再グループ化でもこの割り当ては維持される
    func assignManually(_ tabID: UUID, to group: String?) {
        let name = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            assignments[tabID] = name
        } else {
            assignments.removeValue(forKey: tabID)
        }
        pinned.insert(tabID)
    }

    // タブを閉じたときの片付け
    func forget(_ tabID: UUID) {
        assignments.removeValue(forKey: tabID)
        pinned.remove(tabID)
    }

    private func regroup(tabs: [Tab], minimumTabs: Int = 4) async {
        isWorking = true
        defer { isWorking = false }

        // ロビー・タイトル未確定・ピン留め済みのタブは自動割り当ての対象外
        let eligible = tabs.filter {
            !$0.isHome && !$0.pageTitle.isEmpty && !pinned.contains($0.id)
        }

        // 非対応言語と判定されたタイトルのタブを外す。
        // 通常は緩い判定（確信度が高いときだけ弾く）で除外しすぎを防ぐが、
        // 過去に Apple 側で拒否された実績があれば最初から厳しい判定を使う
        let useStrict = preferStrictFilter
        let candidates = eligible.filter { isSupportedLanguage($0.pageTitle, strict: useStrict) }
        let excluded = eligible.count - candidates.count
        print("TabGrouper: start (candidates: \(candidates.count), excluded by language: \(excluded), strict: \(useStrict), pinned: \(pinned.count), minimum: \(minimumTabs))")

        // 自動対象が少なすぎるなら、手動割り当てだけ残して終わる
        guard candidates.count >= minimumTabs else {
            print("TabGrouper: skipped (not enough candidates)")
            assignments = assignments.filter { pinned.contains($0.key) }
            return
        }

        do {
            try await performGrouping(candidates: candidates)
        } catch let error as LanguageModelSession.GenerationError {
            // 緩い判定をすり抜けたタイトルが拒否された場合、
            // 以降のために学習した上で、厳しい判定で絞り直して一度だけやり直す
            guard case .unsupportedLanguageOrLocale = error else {
                print("TabGrouper: failed: \(error)")
                return
            }
            preferStrictFilter = true
            guard !useStrict else {
                // 既に厳しい判定でも拒否された。今回は諦める
                print("TabGrouper: failed even with strict filter: \(error)")
                return
            }
            let strict = eligible.filter { isSupportedLanguage($0.pageTitle, strict: true) }
            guard strict.count >= minimumTabs, strict.count < candidates.count else {
                print("TabGrouper: failed: \(error)")
                return
            }
            print("TabGrouper: unsupported language, retrying with strict filter (candidates: \(strict.count))")
            do {
                try await performGrouping(candidates: strict)
            } catch {
                print("TabGrouper: failed: \(error)")
            }
        } catch {
            print("TabGrouper: failed: \(error)")
        }
    }

    // 候補一覧をモデルに渡してグループ分けし、結果を assignments に反映する
    private func performGrouping(candidates: [Tab]) async throws {
        // モデルに渡す一覧：「番号: タイトル (ホスト名)」。
        // タイトルは必ず sanitize を通す。言語判定と送信内容を同じ文に
        // 揃えないと、こちらで通した行が Apple 側で弾かれる事故が起きる。
        // 掃除の結果タイトルが空になったら（@ハンドルだけのタイトル等）、
        // ホスト名だけの行にする
        let listing = candidates.enumerated().map { idx, tab in
            let host = tab.webView.url?.host() ?? ""
            let title = sanitize(tab.pageTitle)
            return title.isEmpty
                ? "\(idx): (\(host))"
                : "\(idx): \(title) (\(host))"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            あなたはブラウザのタブを整理する係です。
            与えられたタブ一覧を、話題やサイトの種類ごとに2〜5個のグループへ分けてください。
            グループ名は短く付けてください。
            どのグループにも合わないタブは無理に入れず、省いて構いません。
            """)

        // 既存のグループ名をヒントとして渡す。
        // 名前の揺れ（同じ内容なのに毎回別名になる）を抑える
        let existingNames = Array(Set(assignments.values)).sorted()
        let hint = existingNames.isEmpty
            ? ""
            : "\n既にあるグループ名（内容が合うなら再利用してください）: \(existingNames.joined(separator: "、"))"

        let response = try await session.respond(
            to: "次のタブをグループ分けしてください:\n\(listing)\(hint)",
            generating: TabGroupingResult.self
        )

        // 手動割り当て（ピン留め）を土台に、自動の結果を重ねる
        var newAssignments = assignments.filter { pinned.contains($0.key) }
        for group in response.content.groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for number in group.tabNumbers {
                // モデルが実在しない番号を返しても落ちないように守る
                guard candidates.indices.contains(number) else { continue }
                newAssignments[candidates[number].id] = name
            }
        }
        assignments = newAssignments
        print("TabGrouper: done (\(response.content.groups.count) groups)")
    }

    // @ハンドル・URLなど、言語判定を狂わせるノイズを取り除く。
    // 言語判定（isSupportedLanguage）とモデルへの送信文の両方で
    // 必ずこれを通し、判定対象と実際に送る文を一致させる
    private func sanitize(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "@[A-Za-z0-9_]+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "https?://\\S+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // タイトルの言語がモデルの対応言語かどうか（sanitize 済みの文で判定）。
    // strict = false：確信度が高く非対応と分かったときだけ弾く（通常運転）
    // strict = true ：非対応が最有力なら弾く（拒否された実績があるとき）
    private func isSupportedLanguage(_ text: String, strict: Bool) -> Bool {
        let cleaned = sanitize(text)
        guard !cleaned.isEmpty else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cleaned)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else {
            return true
        }
        // 短いタイトルの言語判定は揺れるので、緩い判定では
        // 確信度 0.6 超のときだけ除外の対象にする
        if !strict && confidence <= 0.6 { return true }

        let code = Locale.Language(identifier: language.rawValue).languageCode?.identifier
            ?? language.rawValue
        let supportedCodes = Set(
            SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier }
        )
        return supportedCodes.contains(code)
    }
}
