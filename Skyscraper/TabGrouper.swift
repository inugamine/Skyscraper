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

import Foundation
import Combine
import WebKit
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
        let candidates = tabs.filter {
            !$0.isHome && !$0.pageTitle.isEmpty && !pinned.contains($0.id)
        }
        print("TabGrouper: start (candidates: \(candidates.count), pinned: \(pinned.count), minimum: \(minimumTabs))")

        // 自動対象が少なすぎるなら、手動割り当てだけ残して終わる
        guard candidates.count >= minimumTabs else {
            print("TabGrouper: skipped (not enough candidates)")
            assignments = assignments.filter { pinned.contains($0.key) }
            return
        }

        // モデルに渡す一覧：「番号: タイトル (ホスト名)」
        let listing = candidates.enumerated().map { idx, tab in
            let host = tab.webView.url?.host() ?? ""
            return "\(idx): \(tab.pageTitle) (\(host))"
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

        do {
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
        } catch {
            // ガードレール判定・コンテキスト超過などで失敗することがある。
            // その場合は黙って現状のグループを維持する
            print("TabGrouper: failed: \(error)")
        }
    }
}
