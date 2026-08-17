//
//  Translator.swift
//  Skyscraper
//
//  選択した文字列を Apple 純正の翻訳エンジン（Translation フレームワーク）で訳す。
//  処理は端末内で完結し、原文が外部へ送られることはない。
//
//  Apple Intelligence とは無関係に動く。設定でオフにしていても、
//  対応していない機種でも翻訳は使える（Safari の翻訳と同じ土台）。
//
//  設計上の要：TranslationSession は自前で作れない。
//  イニシャライザが公開されておらず、SwiftUI の
//  .translationTask(_:action:) モディファイアからしか降ってこない。
//  そのため、この型は「状態と configuration を持つ側」に徹し、
//  実際の翻訳は外から渡されたセッションを使う perform(with:) で行う。
//
//      // ContentView 側
//      .translationTask(translator.configuration) { session in
//          await translator.perform(with: session)
//      }
//
//  configuration に値が入る、または中身が変わった瞬間にモディファイアが発火する。
//  同じ言語ペアのまま別の文を訳し直したい時は値が変わらないので発火しない。
//  その場合は invalidate() を叩いて明示的に呼び直す。
//
//  言語の自動判定は Translation ではなく NaturalLanguage に任せる。
//  Configuration の source に nil を渡せばフレームワーク側でも判定してくれるが、
//  それだと「何語と判定されたか」が画面に出せず、
//  「訳先と同じ言語だったら訳先を切り替える」という芸もできない。
//

import Foundation
import Combine
import NaturalLanguage
import Translation
import WebKit

@MainActor
final class Translator: ObservableObject {

    // MARK: - 状態

    enum Phase: Equatable {
        case idle                 // 何もしていない
        case preparing            // 言語資源の用意待ち（初回はここでダウンロードの確認が出る）
        case translating          // 翻訳中
        case done(String)         // 訳文
        case failed(String)       // 表示用のエラー文
    }

    @Published private(set) var phase: Phase = .idle

    // パネルの開閉。閉じても原文と訳文は残す（開き直した時に前回が見える）
    @Published var isPresented = false

    // 原文（選択された文字列そのもの。判定用の掃除はここには掛けない）
    @Published private(set) var sourceText = ""

    // NaturalLanguage が判定した原文の言語。確信が持てなければ nil
    @Published private(set) var detectedLanguage: Locale.Language?

    // 利用者が手で選んだ原文の言語。nil なら自動判別に任せる。
    // 判別できなかった時だけでなく、判別が外れている時にも上書きできる。
    // didSet は使わず setSourceLanguage(_:) を通す。
    // 新しい選択を受けた時にここを素で戻す必要があり、
    // didSet だとそのたびに翻訳が走ってしまう
    @Published private(set) var manualSourceLanguage: Locale.Language?

    // 訳先。変えたら即座に訳し直す
    @Published var targetLanguage: Locale.Language {
        didSet {
            guard targetLanguage != oldValue else { return }
            saveTargetLanguage()
            guard !sourceText.isEmpty else { return }
            requestSession()
        }
    }

    // 訳先の選択肢。起動後に一度だけ埋まる
    @Published private(set) var availableLanguages: [Locale.Language] = []

    // .translationTask に渡す種。ここが変わるとセッションが降ってくる
    @Published private(set) var configuration: TranslationSession.Configuration?

    // MARK: - 内部

    // configuration の中身を自前でも控えておく。
    // 「前回と同じ言語ペアか」の判定に使う（同じなら invalidate で呼び直す）
    private var currentSource: Locale.Language?
    private var currentTarget: Locale.Language?

    // 一度に投げる原文の上限。
    // これを超える選択は頭から切り出す。段落ごとに分けて
    // バッチ翻訳する手もあるが、まずは単発で通す
    private let characterLimit = 5000

    // 言語判定を信用する最低文字数。
    // 数文字の断片では NLLanguageRecognizer は当てにならない
    private let minimumLengthForDetection = 8

    private let defaultsKey = "skyscraper.translate.target.v1"

    // MARK: - 初期化

    init() {
        // 保存済みの訳先があればそれを、無ければシステムの言語を使う
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), !saved.isEmpty {
            targetLanguage = Locale.Language(identifier: saved)
        } else {
            targetLanguage = Locale.current.language
        }
        Task { await loadAvailableLanguages() }
    }

    // MARK: - 入口

    // 選択された文字列を受け取って翻訳を始める。
    // 実際に走るのは .translationTask が発火した後（perform(with:) の中）
    func translate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed(String(localized: "No text is selected."))
            isPresented = true
            return
        }

        sourceText = String(trimmed.prefix(characterLimit))
        // 新しい文になったら、前の手動指定は引き継がない。
        // 英語の段落のために選んだ設定が、次に選んだ中国語にまで付いて回っては困る
        manualSourceLanguage = nil
        detectedLanguage = detectLanguage(of: sourceText)

        // 原文と訳先が同じなら、訳先を控えの言語へ振り替える。
        // 日本語のページで日本語→日本語を投げても意味が無い
        if let detected = detectedLanguage, sameLanguage(detected, targetLanguage) {
            targetLanguage = fallbackTarget(avoiding: detected)
            // didSet が requestSession を呼ぶので、ここで二重に呼ばない
            isPresented = true
            return
        }

        isPresented = true
        requestSession()
    }

    // ページで選択されている文字列を取ってきて訳す。
    //
    // 拾えるのはメインフレームの選択だけだ。埋め込み（iframe 内の
    // コメント欄など）の選択は window.getSelection() には現れない。
    // 全フレームを回るには WKFrameInfo を集めて一つずつ評価する必要があるが、
    // 常用する場面が思い当たらないので今は追わない。
    //
    // 入力欄（input / textarea）の中の選択も getSelection には出ないので、
    // そちらは selectionStart / selectionEnd から拾う
    func translateSelection(in webView: WKWebView) {
        let js = """
        (() => {
            const el = document.activeElement;
            if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')
                && typeof el.selectionStart === 'number') {
                const picked = el.value.substring(el.selectionStart, el.selectionEnd);
                if (picked) { return picked; }
            }
            return window.getSelection().toString();
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    print("Translator: could not read selection: \(error)")
                }
                self.translate(result as? String ?? "")
            }
        }
    }

    // 同じ原文をもう一度訳す（言語を変えた後など）
    func retry() {
        guard !sourceText.isEmpty else { return }
        requestSession()
    }

    // 原文の言語を手で指定する。nil を渡せば自動判別に戻る
    func setSourceLanguage(_ language: Locale.Language?) {
        guard manualSourceLanguage != language else { return }
        manualSourceLanguage = language
        guard !sourceText.isEmpty else { return }

        // 指定した原文の言語が訳先とぶつかったら、訳先を逃がす。
        // targetLanguage の didSet が requestSession を呼ぶので二重に呼ばない
        if let language, sameLanguage(language, targetLanguage) {
            targetLanguage = fallbackTarget(avoiding: language)
            return
        }
        requestSession()
    }

    func close() {
        isPresented = false
    }

    // 訳文を書き出す（コピー用）
    var translatedText: String? {
        if case .done(let text) = phase { return text }
        return nil
    }

    // MARK: - セッションの要求

    // configuration を更新して .translationTask を発火させる。
    // 言語ペアが前回と同じだと値が変わらず発火しないので、
    // その場合は invalidate() で明示的に呼び直す
    private func requestSession() {
        phase = .preparing

        // 手で選ばれていればそれを優先。どちらも無ければ source は nil にして
        // フレームワーク側の判定に任せる（間違った source を渡すより安全）
        let source = manualSourceLanguage ?? detectedLanguage
        let target = targetLanguage

        if currentSource == source, currentTarget == target, configuration != nil {
            configuration?.invalidate()
        } else {
            currentSource = source
            currentTarget = target
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    // MARK: - 実行（セッションは .translationTask から注入される）

    func perform(with session: TranslationSession) async {
        let text = sourceText
        guard !text.isEmpty else { return }

        do {
            // 言語資源が未取得なら、ここでシステムのダウンロード確認が出る。
            // 先に済ませておかないと、translate の中で確認が出た挙句
            // ユーザーが断った時の扱いが分かりにくくなる
            try await session.prepareTranslation()

            // 待っている間に別の文が選ばれていたら、この結果は捨てる
            guard text == sourceText else { return }
            phase = .translating

            let response = try await session.translate(text)
            guard text == sourceText else { return }
            phase = .done(response.targetText)
        } catch is CancellationError {
            // 別の要求に乗り換えただけ。何も出さない
        } catch {
            guard text == sourceText else { return }
            print("Translator: failed: \(error)")
            phase = .failed(message(for: error))
        }
    }

    // MARK: - 言語判定

    // 原文の言語を推定する。短すぎる・確信が持てない場合は nil
    private func detectLanguage(of text: String) -> Locale.Language? {
        let cleaned = sanitize(text)
        guard cleaned.count >= minimumLengthForDetection else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cleaned)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.5 else {
            return nil
        }
        return Locale.Language(identifier: language.rawValue)
    }

    // @ハンドル・URL といった、言語判定を狂わせるノイズを落とす。
    // 判定にだけ使い、翻訳へ送る原文はいじらない
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

    // 地域や文字種の違いを無視して、同じ言語かどうかを見る。
    // ja-JP と ja、en-US と en を別物として扱うと訳先の振り替えが働かない
    private func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode
    }

    // 原文と訳先がぶつかった時の逃げ先。
    // 日本語圏の利用が主なので、日本語なら英語へ、それ以外なら日本語へ倒す
    private func fallbackTarget(avoiding language: Locale.Language) -> Locale.Language {
        let english = Locale.Language(identifier: "en")
        let japanese = Locale.Language(identifier: "ja")
        return sameLanguage(language, english) ? japanese : english
    }

    // MARK: - 訳先の選択肢

    private func loadAvailableLanguages() async {
        let languages = await LanguageAvailability().supportedLanguages
        // 表示名で並べ替える。同じ言語の地域違いは一つにまとめる
        var seen = Set<String>()
        var unique: [Locale.Language] = []
        for language in languages {
            guard let code = language.languageCode?.identifier else { continue }
            guard seen.insert(code).inserted else { continue }
            unique.append(language)
        }
        availableLanguages = unique.sorted {
            Self.displayName(of: $0).localizedCompare(Self.displayName(of: $1)) == .orderedAscending
        }
    }

    // 言語の表示名（利用者の言語で）。取れなければコードをそのまま出す
    static func displayName(of language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "—" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // 盤に出す原文の言語名。手動指定 > 自動判別 > 不明
    var sourceLanguageName: String {
        guard let language = manualSourceLanguage ?? detectedLanguage else {
            return String(localized: "Unknown")
        }
        return Self.displayName(of: language)
    }

    // MARK: - 保存

    private func saveTargetLanguage() {
        guard let code = targetLanguage.languageCode?.identifier else { return }
        UserDefaults.standard.set(code, forKey: defaultsKey)
    }

    // MARK: - エラー文

    // 画面に出す一行。細かい事情はコンソールへ流し、
    // 利用者には「次に何をすればいいか」だけを見せる
    private func message(for error: Error) -> String {
        let nsError = error as NSError
        // 言語資源が未取得のまま断られた場合
        if nsError.domain == "TranslationErrorDomain" {
            return String(localized: "This language pair isn’t available. Check the language settings in System Settings.")
        }
        return String(localized: "Translation failed.")
    }
}
