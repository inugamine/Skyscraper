//
//  Theodore.swift
//  Skyscraper
//
//  セオドア。館内案内板 (⌘K) に詰めているエレベーターボーイ。
//  打ち込んだお願いを Apple Intelligence (Foundation Models) で読み解き、
//  案内板の行を代わりに押してくれる。処理は全てオンデバイスで、外へは何も送らない。
//
//  ── 作りの方針 ──
//  モデルに道具 (Tool) を渡して勝手に実行させることはしない。
//  小さなモデルが取り違えた時に、止める暇が無いからだ。
//  モデルには「何をするか」「どれに対してか」を型 (@Generable) で答えさせるだけにして、
//  実行するのはこちらの Swift。一覧に無い番号が返ってきたら捨てる。
//
//  読み解きは二段：
//    一段目  お願いの種類を当てる (閉じる / ブックマークを開く / 承れない)
//    二段目  種類に合った一覧だけを見せて、相手を選ばせる
//  全部の一覧を一度に渡すより小さなモデルが迷わないし、窓 (文脈長) にも収まる。
//
//  ── 確認 ──
//  閉じる系は提案を見せて、↩ で実行する (まとめて閉じると戻すのが手間)。
//  開く系はすぐ実行する (間違えても戻るで済む)。
//
//  ── 台詞 ──
//  セオドアの台詞はモデルに書かせず、こちらで用意した定型文を出す。
//  枚数や題がモデルの作文と食い違う事故を避けるためで、訳も効く。
//

import AppKit
import Combine
import Foundation
import FoundationModels
import os

// MARK: - モデルに答えさせる型

@Generable
enum TheodoreIntent {
    case closeTabs
    case openBookmark
    case unsupported
}

@Generable
struct TheodoreIntentAnswer {
    @Guide(description: "お願いの種類")
    var intent: TheodoreIntent
}

@Generable
struct TheodoreTabPick {
    // 番号より先に「何を閉じたいのか」を書かせる。後の照合の手掛かりになる
    @Guide(description: "お願いが「このタブ」「今のタブ」のように、今見ているタブを指しているなら true")
    var meansCurrentTab: Bool

    @Guide(description: "閉じたいタブの手掛かり。サイトの名前や話題を短く (例:「Apple 関連のタブ」なら「Apple」)。「タブ」「ページ」のような言葉は付けない")
    var target: String

    @Guide(description: "お願いに当てはまるタブの番号。一覧にある番号だけを使う")
    var tabNumbers: [Int]
}

// 一枚だけを見せて「お願いに当てはまるか」を答えさせる。
// ブックマークの TheodoreSameSite と同じ理由——一覧から選ばせると、
// 当てはまる物が無くても何かしら選んでしまう
@Generable
struct TheodoreTabMatch {
    @Guide(description: "このタブがお願いに当てはまるなら true。関係の無いサイトなら false")
    var matches: Bool
}

@Generable
struct TheodoreBookmarkPick {
    // 先に「何を開きたいのか」を書かせる。後の照合 (verify) の手掛かりにもなる
    @Guide(description: "利用者が開きたいサイトやページの名前。お願いの文から抜き出す。「サイト」「ページ」のような言葉は付けない (例:「天気のサイト」なら「天気」)")
    var siteName: String

    @Guide(description: "そのサイトに当たるブックマークの番号。当てはまるものが無ければ -1")
    var bookmarkNumber: Int
}

// 一組だけを見せて「同じサイトか」を答えさせる。
// 小さなモデルは一覧から選ぶ時に「無い」と言えず、何かしら選んでしまう。
// 一組の正誤なら、ずっと素直に答えられる
@Generable
struct TheodoreSameSite {
    @Guide(description: "開きたいサイトとブックマークが同じサイト・同じページを指しているなら true。名前が似ているだけの別のサイトなら false")
    var isSame: Bool
}

// MARK: - 台詞

enum TheodoreLines {
    static var thinking: String {
        String(localized: "Going up. One moment, please…")
    }
    static func proposeClose(_ count: Int) -> String {
        String(localized: "Certainly. Shall I close these \(count) tabs?")
    }
    static func keptPinned(_ count: Int) -> String {
        String(localized: "The \(count) pinned tabs will stay as they are.")
    }
    static var noMatchingTabs: String {
        String(localized: "I'm terribly sorry. I couldn't find any tabs like that.")
    }
    static var onlyPinned: String {
        String(localized: "I'm sorry, but those tabs are pinned. Please unpin them first.")
    }
    static var noBookmark: String {
        String(localized: "I'm terribly sorry. There's no bookmark like that on our shelves.")
    }
    static func offerSearch(_ query: String) -> String {
        String(localized: "I'm terribly sorry. There's no bookmark like that on our shelves. Shall I search the web for “\(query)” instead?")
    }
    static var unsupported: String {
        String(localized: "My apologies. For now, I can only close tabs and open bookmarks or web searches.")
    }
    static var tooMuch: String {
        String(localized: "My apologies. That's more than I can keep in mind at once.")
    }
    static var failed: String {
        String(localized: "My apologies. Something went wrong. Please try once more.")
    }
}

// MARK: - 状態

// 閉じる提案に並べる一枚
struct TheodoreTabItem: Identifiable {
    let id: UUID
    let title: String
    let host: String
    let favicon: NSImage?
}

enum TheodoreState {
    case idle
    case thinking(request: String)
    case proposeClose(request: String, tabs: [TheodoreTabItem], keptPinned: Int)
    // 棚に無かったので、代わりにウェブ検索を勧める。open は ↩ で走らせる中身
    case proposeSearch(request: String, query: String, open: @MainActor () -> Void)
    case message(request: String, text: String)
}

// MARK: - セオドア

@MainActor
final class Theodore: ObservableObject {
    @Published private(set) var state: TheodoreState = .idle

    private static let log = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                                    category: "Theodore")

    // 同じお願いには同じ答えを返してほしい。揺らぎは要らない
    private static let options = GenerationOptions(samplingMode: .greedy)

    // ブックマークを見せる上限。これを越えると窓からあふれかねない
    private static let bookmarkLimit = 120

    // 今のお願いの番号。考えている間に打ち直されたり、
    // 盤が閉じられたりしたら、古い答えは捨てる
    private var ticket = 0

    // 一度でも Apple 側の言語判定に断られたら true。
    // 以降は最初から厳しい判定で一覧を絞る (TabGrouper と同じ手。再起動で戻る)
    private static var preferStrict = false

    // Apple Intelligence が使えるか。使えない Mac ではセオドアは出てこない
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    var isThinking: Bool {
        if case .thinking = state { return true }
        return false
    }

    var request: String {
        switch state {
        case .idle: ""
        case .thinking(let request),
             .proposeClose(let request, _, _),
             .proposeSearch(let request, _, _),
             .message(let request, _): request
        }
    }

    var line: String {
        switch state {
        case .idle: ""
        case .thinking: TheodoreLines.thinking
        case .proposeClose(_, let tabs, _): TheodoreLines.proposeClose(tabs.count)
        case .proposeSearch(_, let query, _): TheodoreLines.offerSearch(query)
        case .message(_, let text): text
        }
    }

    // 盤を元の一覧に戻す。考え中の答えも捨てる
    func reset() {
        ticket &+= 1
        state = .idle
    }

    // お願いする。開く系はその場で実行まで済ませる。
    // done は盤を畳むための合図 (実行の前に呼ぶ——盤が出たままだと焦点を奪われる)
    func ask(_ text: String,
             manager: TabManager,
             bookmarks: [Bookmark],
             done: @escaping @MainActor () -> Void) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isThinking else { return }
        ticket &+= 1
        let mine = ticket
        state = .thinking(request: request)
        Task {
            let outcome = await self.work(request, manager: manager, bookmarks: bookmarks)
            guard mine == self.ticket else { return }
            switch outcome {
            case .state(let next):
                self.state = next
            case .perform(let action):
                self.state = .idle
                done()
                DispatchQueue.main.async { action() }
            }
        }
    }

    // 提案を呑む (↩)
    func confirm(done: @escaping @MainActor () -> Void) {
        if case .proposeSearch(_, _, let open) = state {
            ticket &+= 1
            state = .idle
            done()
            DispatchQueue.main.async { open() }
            return
        }
        guard case .proposeClose(_, let tabs, _) = state else { return }
        ticket &+= 1
        state = .idle
        done()
        DispatchQueue.main.async {
            for item in tabs {
                // 提案から実行までの間に留められた物は閉じない
                guard let (owner, tab) = TabManager.owner(of: item.id), !tab.isPinned else { continue }
                owner.closeTab(tab)
            }
        }
    }

    // MARK: 読み解き

    private enum Outcome {
        case state(TheodoreState)
        case perform(@MainActor () -> Void)
    }

    private func work(_ request: String,
                      manager: TabManager,
                      bookmarks: [Bookmark]) async -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        defer {
            let elapsed = started.duration(to: clock.now)
            Self.log.info("finished in \(String(describing: elapsed), privacy: .public)")
        }
        do {
            let intent = try await classify(request)
            Self.log.info("intent: \(String(describing: intent), privacy: .public) (\(String(describing: started.duration(to: clock.now)), privacy: .public))")
            switch intent {
            case .closeTabs:
                return try await pickTabs(request, manager: manager)
            case .openBookmark:
                // 隠し芸。お願いに番地が書いてあれば、棚を見ずにそこへ行く
                if let url = Self.address(in: request) {
                    Self.log.info("open: address in request")
                    return .perform { Self.open(url, in: manager) }
                }
                return try await pickBookmark(request, manager: manager, bookmarks: bookmarks)
            case .unsupported:
                return .state(.message(request: request, text: TheodoreLines.unsupported))
            }
        } catch let error as LanguageModelSession.GenerationError {
            Self.log.error("failed: \(String(describing: error), privacy: .public)")
            if case .exceededContextWindowSize = error {
                return .state(.message(request: request, text: TheodoreLines.tooMuch))
            }
            return .state(.message(request: request, text: TheodoreLines.failed))
        } catch {
            Self.log.error("failed: \(String(describing: error), privacy: .public)")
            return .state(.message(request: request, text: TheodoreLines.failed))
        }
    }

    // 一段目。お願いの種類を当てる
    private func classify(_ request: String) async throws -> TheodoreIntent {
        let session = LanguageModelSession(instructions: """
            あなたはブラウザの操作係です。
            利用者のお願いを読んで、次のどれに当たるかを選んでください。
            closeTabs: 開いているタブを閉じるお願い。例「Apple 関連のタブを閉じて」「このタブを閉じて」「YouTube のタブを全部閉じて」
            openBookmark: サイトやページを開くお願い。例「GitHub を開いて」「天気のサイトを開いて」
            unsupported: それ以外のお願い
            """)
        let response = try await session.respond(to: "お願い: \(request)",
                                                 generating: TheodoreIntentAnswer.self,
                                                 options: Self.options)
        return response.content.intent
    }

    // 二段目 (閉じる)。全ての窓のタブから当てはまる物を選ばせ、提案にする
    private func pickTabs(_ request: String, manager: TabManager) async throws -> Outcome {
        // 並びと範囲はタブ検索と同じ (普通の窓とプライベートは互いに見えない)
        let all = TabSearch.matches(query: "", from: manager)
        guard !all.isEmpty else {
            return .state(.message(request: request, text: TheodoreLines.noMatchingTabs))
        }

        // お願いに番地が書いてあれば ("apple.com のタブを閉じて")、モデルは使わない。
        // ホストで突き合わせれば答えは一つに決まる。開いていなければ、無いと言う
        if let url = Self.address(in: request), let host = url.host() {
            let chosen = all.filter { Self.host($0.host, isWithin: host) }
            Self.log.info("tabs: by address, \(chosen.count, privacy: .public)")
            return proposeClosing(chosen, request: request)
        }

        let currentID = manager.selectedTab?.id
        let lines = all.map { match in
            (title: match.title,
             note: [match.host, match.id == currentID ? "今見ているタブ" : ""]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        }
        let answer = try await pick(
            instructions: """
                あなたはブラウザのタブを整理する係です。
                利用者のお願いに当てはまるタブを、一覧から全て選んでください。
                当てはまるか迷うものは選ばないでください。当てはまるものが無ければ、何も選ばないでください。
                「このタブ」「今のタブ」は「今見ているタブ」の印が付いたものを指します。
                """,
            request: request,
            heading: "タブ一覧",
            lines: lines,
            generating: TheodoreTabPick.self)

        // 「このタブ」は番号ではなく、こちらが知っている今のタブで決める
        if answer.meansCurrentTab {
            let chosen = all.filter { $0.id == currentID }
            Self.log.info("tabs: current tab")
            return proposeClosing(chosen, request: request)
        }

        // 選ばれた物を一枚ずつ確かめる。
        // 手掛かりが題やホストにそのまま入っていれば文句なし。
        // 入っていなければ一枚だけ見せて訊き直す (9to5Mac を「Apple 関連」と見るような場合)
        let picked = Set(answer.tabNumbers.filter { all.indices.contains($0) })
        var chosen: [TabSearchMatch] = []
        var asked = 0
        for match in all.indices.filter({ picked.contains($0) }).map({ all[$0] }) {
            if Self.mentions([match.title, match.host], answer.target) {
                chosen.append(match)
                continue
            }
            // 訊き直しは一枚あたり一往復かかる。際限なく待たせない
            guard asked < Self.verifyLimit else { continue }
            asked += 1
            if try await verify(request: request, target: answer.target, tab: match) {
                chosen.append(match)
            }
        }
        Self.log.info("tabs: picked \(picked.count, privacy: .public), kept \(chosen.count, privacy: .public), asked \(asked, privacy: .public)")
        return proposeClosing(chosen, request: request)
    }

    // 一度に訊き直す枚数の上限
    private static let verifyLimit = 8

    // 決まった物を提案にする。ピン留めは ⌘W と同じく閉じない
    private func proposeClosing(_ chosen: [TabSearchMatch], request: String) -> Outcome {
        let closable = chosen.filter { !$0.isPinned }
        let keptPinned = chosen.count - closable.count
        guard !closable.isEmpty else {
            let text = keptPinned > 0 ? TheodoreLines.onlyPinned : TheodoreLines.noMatchingTabs
            return .state(.message(request: request, text: text))
        }
        let items = closable.map {
            TheodoreTabItem(id: $0.id, title: $0.title, host: $0.host, favicon: $0.favicon)
        }
        return .state(.proposeClose(request: request, tabs: items, keptPinned: keptPinned))
    }

    // タブのホストが、お願いに書かれた番地の内か。
    // "apple.com" と書けば developer.apple.com も含む。www. の有無は問わない
    private static func host(_ tabHost: String, isWithin requested: String) -> Bool {
        func bare(_ host: String) -> String {
            let lower = host.lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        let tab = bare(tabHost)
        let want = bare(requested)
        guard !tab.isEmpty, !want.isEmpty else { return false }
        return tab == want || tab.hasSuffix("." + want)
    }

    // 一枚だけを見せて、お願いに当てはまるかを答えさせる。
    // 言語の都合で断られたら「当てはまらない」として扱う (閉じ過ぎるよりはまし)
    private func verify(request: String, target: String, tab: TabSearchMatch) async throws -> Bool {
        let session = LanguageModelSession(instructions: """
            あなたはブラウザのタブを整理する係です。
            利用者が閉じたいタブの手掛かりと、一枚のタブを見て、このタブが閉じる対象に当てはまるかを判定してください。
            手掛かりと関係の無いサイトなら false です。
            """)
        let prompt = """
            お願い: \(request)
            手掛かり: \(target)
            タブ: \(ModelLanguage.sanitize(tab.title)) (\(tab.host))
            """
        do {
            return try await session.respond(to: prompt,
                                             generating: TheodoreTabMatch.self,
                                             options: Self.options).content.matches
        } catch let error as LanguageModelSession.GenerationError {
            guard case .unsupportedLanguageOrLocale = error else { throw error }
            return false
        }
    }

    // 二段目 (開く)。棚から一つ選ばせ、2F と同じく今のタブで開く
    private func pickBookmark(_ request: String,
                              manager: TabManager,
                              bookmarks: [Bookmark]) async throws -> Outcome {
        let shelf = Array(bookmarks.prefix(Self.bookmarkLimit))
        guard !shelf.isEmpty else {
            return offerSearch(request, query: request, manager: manager)
        }
        let lines = shelf.map { bookmark in
            let host = URL(string: bookmark.url)?.host() ?? ""
            let folders = (bookmark.folder ?? []).joined(separator: " › ")
            return (title: bookmark.title,
                    note: [host, folders].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        let answer = try await pick(
            instructions: """
                あなたはブックマークの案内係です。
                利用者が開きたいサイトに最も合うブックマークを、一覧から一つだけ選んでください。
                当てはまるものが無ければ -1 を選んでください。
                """,
            request: request,
            heading: "ブックマーク一覧",
            lines: lines,
            generating: TheodoreBookmarkPick.self)

        guard shelf.indices.contains(answer.bookmarkNumber) else {
            Self.log.info("bookmark: none (\(answer.bookmarkNumber, privacy: .public))")
            return offerSearch(request, query: answer.siteName, manager: manager)
        }
        let bookmark = shelf[answer.bookmarkNumber]

        // 選んだ物が本当に当たりかを確かめる。
        // 名前が題や URL にそのまま入っていれば文句なし。
        // 入っていなければ (「天気のサイト」→ tenki.jp のような場合)、一組だけ見せて訊き直す
        if Self.mentions(bookmark, answer.siteName) {
            Self.log.info("bookmark: matched by name")
        } else {
            let same = try await verifyBookmark(request: request,
                                                siteName: answer.siteName,
                                                bookmark: bookmark)
            Self.log.info("bookmark: verified \(same, privacy: .public)")
            guard same else {
                return offerSearch(request, query: answer.siteName, manager: manager)
            }
        }

        return .perform {
            if let tab = manager.selectedTab {
                tab.open(bookmark: bookmark.url)
            } else {
                manager.addTab(url: bookmark.url)
            }
        }
    }

    // 棚に無かった時の、ウェブ検索の提案。
    // 検索語はモデルが抜き出したサイトの名前 (空ならお願いの文そのまま)。
    // 開く先はブックマークと同じく今のタブ。
    // 「tenki.jp」のような番地らしい語でも必ず検索にかける——
    // 推測した番地へ直に飛ばすと、でっち上げの URL を踏みかねない
    private func offerSearch(_ request: String, query: String, manager: TabManager) -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty ? request : trimmed
        guard let url = Tab.searchURL(for: words) else {
            return .state(.message(request: request, text: TheodoreLines.noBookmark))
        }
        return .state(.proposeSearch(request: request, query: words, open: {
            Self.open(url, in: manager)
        }))
    }

    // 今のタブで開く (ブックマークと同じ流儀)。タブが無ければ新しく開く
    private static func open(_ url: URL, in manager: TabManager) {
        if let tab = manager.selectedTab {
            tab.urlText = url.absoluteString
            tab.load()
        } else {
            manager.addTab(url: url.absoluteString)
        }
    }

    // お願いの文に書かれた番地 ("GitHub.com を開いて" の GitHub.com)。
    //
    // 番地は利用者が自分で打った文字から拾う。モデルには作らせない——
    // モデルに推測させるとでっち上げの番地を踏みかねないが、
    // 利用者が書いた物なら、アドレスバーに打ったのと同じことだ。
    //
    // 日本語に続けて書かれても拾えるよう、前後は英数字かどうかで区切る
    // (\b は「を」も単語の文字と見るので "GitHub.comを" で切れない)。
    // 末尾は英字二文字以上の TLD に限る。"1.5" のような数は拾わない
    private static let addressPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9.@-])(?:https?://)?(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,}(?::[0-9]+)?(?:/[!-~]*)?(?![A-Za-z0-9-])",
        options: [])

    private static func address(in request: String) -> URL? {
        let range = NSRange(request.startIndex..., in: request)
        guard let match = addressPattern.firstMatch(in: request, range: range),
              let found = Range(match.range, in: request) else { return nil }
        // 開き方はアドレスバーと同じ見分けに任せる
        if case .web(let url) = Tab.interpret(String(request[found])) {
            return url
        }
        return nil
    }

    // 開きたいサイトの名前が、ブックマークの題・ホスト・URL にそのまま入っているか。
    // 空白と大文字小文字は無視する ("Git Hub" も "github" も同じ)
    private static func mentions(_ bookmark: Bookmark, _ siteName: String) -> Bool {
        let host = URL(string: bookmark.url)?.host() ?? ""
        return mentions([bookmark.title, host, bookmark.url], siteName)
    }

    private static func mentions(_ haystack: [String], _ name: String) -> Bool {
        func squash(_ text: String) -> String {
            text.lowercased().filter { !$0.isWhitespace }
        }
        let needle = squash(name)
        guard needle.count >= 2 else { return false }
        return haystack.contains { squash($0).contains(needle) }
    }

    // 一組だけを見せて、同じサイトかを答えさせる。
    // 言語の都合で断られたら「違う」として扱う (開き違いよりは断る方がまし)
    private func verifyBookmark(request: String, siteName: String, bookmark: Bookmark) async throws -> Bool {
        let host = URL(string: bookmark.url)?.host() ?? ""
        let title = ModelLanguage.sanitize(bookmark.title)
        let session = LanguageModelSession(instructions: """
            あなたはブックマークの案内係です。
            利用者が開きたいサイトと、棚のブックマークが同じサイトを指しているかを判定してください。
            名前が似ているだけの別のサイトや、同じ分野の別のサイトなら false です。
            """)
        let prompt = """
            お願い: \(request)
            開きたいサイト: \(siteName)
            ブックマーク: \(title) (\(host))
            """
        do {
            return try await session.respond(to: prompt,
                                             generating: TheodoreSameSite.self,
                                             options: Self.options).content.isSame
        } catch let error as LanguageModelSession.GenerationError {
            guard case .unsupportedLanguageOrLocale = error else { throw error }
            return false
        }
    }

    // 番号付きの一覧を見せて選ばせる。
    // 非対応言語と判定された行は外す (番号は元の位置のまま、飛び番になる)。
    // それでも Apple 側に断られたら、厳しい判定で絞り直して一度だけやり直す
    private func pick<T: Generable>(instructions: String,
                                    request: String,
                                    heading: String,
                                    lines: [(title: String, note: String)],
                                    generating type: T.Type) async throws -> T {
        func listing(strict: Bool) -> String {
            lines.enumerated().compactMap { index, line -> String? in
                guard ModelLanguage.isSupported(line.title, strict: strict) else { return nil }
                let title = ModelLanguage.sanitize(line.title)
                let note = line.note.isEmpty ? "" : " (\(line.note))"
                return "\(index): \(title)\(note)"
            }.joined(separator: "\n")
        }
        func send(strict: Bool) async throws -> T {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "お願い: \(request)\n\n\(heading):\n\(listing(strict: strict))"
            return try await session.respond(to: prompt,
                                             generating: type,
                                             options: Self.options).content
        }

        let strict = Self.preferStrict
        do {
            return try await send(strict: strict)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .unsupportedLanguageOrLocale = error, !strict else { throw error }
            Self.preferStrict = true
            Self.log.info("unsupported language, retrying with strict filter")
            return try await send(strict: true)
        }
    }
}
