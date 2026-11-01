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
//    一段目  お願いの種類を当てる
//            (閉じる / 開く / 閉じたタブを開き直す / 今のタブへの操作 / 承れない)
//    二段目  種類に合った一覧だけを見せて、相手を選ばせる
//  小さなモデルは一覧から選ぶ時に「当てはまる物が無い」と言えない。
//  なので選ばせた後、こちらで一件ずつ確かめる (名前がそのまま入っていなければ、
//  一件だけ見せて「当たっているか」を訊き直す)。
//  全部の一覧を一度に渡すより小さなモデルが迷わないし、窓 (文脈長) にも収まる。
//
//  ── 確認 ──
//  閉じる系は提案を見せて、↩ で実行する (まとめて閉じると戻すのが手間)。
//  開く系と 3F の操作はすぐ実行する (間違えても戻るで済む)。
//  3F の「タブを閉じる」が選ばれた時だけは、閉じる系と同じく提案を見せる。
//
//  ── 台詞 ──
//  セオドアの台詞はモデルに書かせず、こちらで用意した定型文を出す。
//  枚数や題がモデルの作文と食い違う事故を避けるためで、訳も効く。
//  同じ文ばかりにならないよう、いくつかの言い回しから選ぶ。
//
//  ── 入り切り ──
//  既定は切 (設定 › General › Theodore)。Skyscraper は、頼まれもしないのに
//  動く AI を載せない。入れても、セオドアが動くのは案内板で頼まれた時だけ。
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
    case reopenClosed
    case pageAction
    case unsupported
}

@Generable
struct TheodoreIntentAnswer {
    @Guide(description: "お願いの種類")
    var intent: TheodoreIntent
}

// 閉じる範囲。「今のタブ」「全部」「今のタブ以外」は番号ではなく、こちらで決める——
// 全部を番号で選ばせると取りこぼすし、手掛かりの照合 (Apple 等) にも掛からない
@Generable
enum TheodoreCloseScope {
    case current
    case all
    case others
    case matching
}

@Generable
struct TheodoreTabPick {
    // 番号より先に「何を閉じたいのか」を書かせる。後の照合の手掛かりになる
    @Guide(description: "閉じる範囲。current: 今見ているタブ (「このタブ」「今のタブ」)。all: この窓のタブ全部 (「タブを全部閉じて」「全部閉じて」)。others: 今見ているタブ以外の全部 (「このタブ以外を閉じて」「他のタブを全部閉じて」)。matching: サイトや話題で絞ったタブ (「Apple 関連のタブを閉じて」)")
    var scope: TheodoreCloseScope

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

@Generable
struct TheodoreClosedPick {
    @Guide(description: "利用者が開き直したいサイトやページの名前。お願いの文から抜き出す。「サイト」「ページ」のような言葉は付けない。特定のページを指していなければ空")
    var siteName: String

    @Guide(description: "そのページに当たる閉じたタブの番号。当てはまるものが無ければ -1")
    var tabNumber: Int
}

@Generable
struct TheodoreActionPick {
    @Guide(description: "利用者がしたいことを短く (例:「このタブをピン留めして」なら「ピン留めする」)")
    var wanted: String

    @Guide(description: "それに当たる操作の番号。当てはまるものが無ければ -1")
    var actionNumber: Int
}

// 切り替え (留める/外す、消す/戻す…) は一覧から番号で選ばせず、
// 名前の付いた選択肢から選ばせる。
// 番号付きの一覧だと、小さなモデルは「リーダー」という字面に引かれて
// 「解除して」でも「リーダーを表示」を選んでしまった (2026-11 実測)。
// 両方の向きを常に並べ、例文を添えると、向きを取り違えにくい
@Generable
enum TheodoreToggle {
    case pin
    case unpin
    case mute
    case unmute
    case showReader
    case hideReader
    case floatTab
    case returnFloatingTab
    case showBookmarksBar
    case hideBookmarksBar
    case showDownloads
    case hideDownloads
    case other
}

@Generable
struct TheodoreToggleAnswer {
    @Guide(description: "お願いに当たる切り替え。どれにも当たらなければ other")
    var toggle: TheodoreToggle

    // 音とピン留めは今のタブ以外も相手にする。その時の手掛かり
    @Guide(description: "お願いが「全部のタブ」「全タブ」「すべてのタブ」に対するものなら true")
    var meansAll: Bool

    @Guide(description: "お願いの中で名指しされたサイトの名前 (例:「YouTube の音戻して」なら「YouTube」)。名指しが無ければ空。「全タブ」のような言葉は名前ではない")
    var siteName: String
}

// 操作は名前が合っていても向きが逆のことがある (「ピン留め」と「ピン留めを外す」)。
// なので名前の一致では決めず、必ずこれで確かめる
@Generable
struct TheodoreActionMatch {
    @Guide(description: "この操作が、利用者のしたいことそのものなら true。逆の操作 (留める⇔外す、表示⇔非表示 など) や別の操作なら false")
    var matches: Bool
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
        [String(localized: "Going up. One moment, please…"),
         String(localized: "Right away. Just a moment, please…"),
         String(localized: "Let me see… one moment, please.")].randomElement()!
    }
    static func proposeClose(_ count: Int) -> String {
        [String(localized: "Certainly. Shall I close these \(count) tabs?"),
         String(localized: "Very well. Shall I close these \(count) tabs for you?")].randomElement()!
    }
    static func keptPinned(_ count: Int) -> String {
        String(localized: "The \(count) pinned tabs will stay as they are.")
    }
    static var noMatchingTabs: String {
        [String(localized: "I'm terribly sorry. I couldn't find any tabs like that."),
         String(localized: "I've looked on every floor, but I couldn't find such a tab.")].randomElement()!
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
        [String(localized: "My apologies. That's not something I can help with yet."),
         String(localized: "I'm afraid that's beyond an elevator attendant's duties."),
         String(localized: "My apologies. That isn't offered on any floor of this building.")].randomElement()!
    }
    static func proposeMute(_ count: Int) -> String {
        String(localized: "Certainly. Shall I mute these \(count) tabs?")
    }
    static func proposeUnmute(_ count: Int) -> String {
        String(localized: "Certainly. Shall I unmute these \(count) tabs?")
    }
    static func proposePin(_ count: Int) -> String {
        String(localized: "Certainly. Shall I pin these \(count) tabs?")
    }
    static func proposeUnpin(_ count: Int) -> String {
        String(localized: "Certainly. Shall I unpin these \(count) tabs?")
    }
    static var alreadyDone: String {
        [String(localized: "Very good. That's already been taken care of."),
         String(localized: "No need to worry. It's already done.")].randomElement()!
    }

    // 打ち込み欄の案内に添える、頼みごとの例
    static var example: String {
        [String(localized: "Close the tabs about Apple"),
         String(localized: "Mute the YouTube tab"),
         String(localized: "Reopen the page I just closed"),
         String(localized: "Pin this tab"),
         String(localized: "Open the weather site")].randomElement()!
    }
    static var cannotDoHere: String {
        String(localized: "I'm terribly sorry. I can't do that for this page right now.")
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
// 名指しで別のタブにも掛けられる操作 (今のタブに限らない)
enum TheodoreTabAction {
    case mute, unmute, pin, unpin

    var isAudio: Bool { self == .mute || self == .unmute }
}

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
    // 音・ピン留めの相手が何枚もあって、決めきれなかった
    case proposeTabs(request: String, tabs: [TheodoreTabItem], action: TheodoreTabAction)
    // 棚に無かったので、代わりにウェブ検索を勧める。open は ↩ で走らせる中身
    case proposeSearch(request: String, query: String, open: @MainActor () -> Void)
    case message(request: String, text: String)
}

// MARK: - セオドア

@MainActor
final class Theodore: ObservableObject {
    @Published private(set) var state: TheodoreState = .idle {
        // 台詞はここで一度だけ選ぶ。描くたびに選ぶと、言い回しがちらつく
        didSet { line = Self.line(for: state) }
    }
    @Published private(set) var line = ""

    // 考え中の進み具合 (0〜1)。紋章の文字盤の針が指す。
    //
    // 何回モデルに訊くかはお願いによって二〜四回と決まっていないので、
    // 一回訊き終わるたびに残りの半分だけ進める (0.29 → 0.65 → 0.82 → 0.91 …)。
    // 嘘の針にはしない——針が上がるのは、本当に一段終わった時だけ。
    // 答えが出たら右端 (1) まで振り切る
    @Published private(set) var progress: Double = 0
    private var steps = 0 {
        didSet { progress = 1 - pow(0.5, Double(steps) + 0.5) }
    }

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
    // 設定の入り切りの鍵。既定は切
    nonisolated static let enabledKey = "theodore.enabled"

    // この Mac で Apple Intelligence が使えるか (設定の注記にも使う)
    static var isModelReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // セオドアを出すか。設定で入れてあって、モデルも使える時だけ
    static var isAvailable: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && isModelReady
    }

    // 盤を開いた時に、一段目の読み解き役を温めておく。
    // モデルを読み込んでおくだけで、何も喋らせない。入りの時しか呼ばれない
    private var warmSession: LanguageModelSession?

    func prewarm() {
        guard Self.isAvailable, warmSession == nil else { return }
        let session = Self.makeIntentSession()
        session.prewarm()
        warmSession = session
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
             .proposeTabs(let request, _, _),
             .proposeSearch(let request, _, _),
             .message(let request, _): request
        }
    }

    private static func line(for state: TheodoreState) -> String {
        switch state {
        case .idle: ""
        case .thinking: TheodoreLines.thinking
        case .proposeClose(_, let tabs, _): TheodoreLines.proposeClose(tabs.count)
        case .proposeTabs(_, let tabs, let action):
            switch action {
            case .mute:   TheodoreLines.proposeMute(tabs.count)
            case .unmute: TheodoreLines.proposeUnmute(tabs.count)
            case .pin:    TheodoreLines.proposePin(tabs.count)
            case .unpin:  TheodoreLines.proposeUnpin(tabs.count)
            }
        case .proposeSearch(_, let query, _): TheodoreLines.offerSearch(query)
        case .message(_, let text): text
        }
    }

    // 札に並べるタブ (閉じる・音の提案の時だけ)
    var proposedTabs: [TheodoreTabItem]? {
        switch state {
        case .proposeClose(_, let tabs, _), .proposeTabs(_, let tabs, _): tabs
        default: nil
        }
    }

    var keptPinned: Int {
        if case .proposeClose(_, _, let kept) = state { return kept }
        return 0
    }

    // ↩ の案内に添える言葉
    var confirmLabel: String {
        switch state {
        case .proposeTabs(_, _, .mute):   String(localized: "Mute Tabs")
        case .proposeTabs(_, _, .unmute): String(localized: "Unmute Tabs")
        case .proposeTabs(_, _, .pin):    String(localized: "Pin Tabs")
        case .proposeTabs(_, _, .unpin):  String(localized: "Unpin Tabs")
        case .proposeSearch:            String(localized: "Search the Web")
        default:                        String(localized: "Close Tabs")
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
             context: DirectoryContext,
             done: @escaping @MainActor () -> Void) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isThinking else { return }
        ticket &+= 1
        let mine = ticket
        steps = 0
        state = .thinking(request: request)
        Task {
            let outcome = await self.work(request, context: context)
            guard mine == self.ticket else { return }
            self.progress = 1
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
        if case .proposeTabs(_, let tabs, let action) = state {
            ticket &+= 1
            state = .idle
            done()
            DispatchQueue.main.async { Self.apply(action, tabs.map(\.id)) }
            return
        }
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

    private func work(_ request: String, context: DirectoryContext) async -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        defer {
            let elapsed = started.duration(to: clock.now)
            Self.log.info("finished in \(String(describing: elapsed), privacy: .public)")
        }
        // お願いの文を控える。.private なので Xcode から動かした時だけ読め、
        // コンソール.app などでは <private> に伏せられる
        Self.log.info("request: \(request, privacy: .private)")
        do {
            let intent = try await classify(request)
            Self.log.info("intent: \(String(describing: intent), privacy: .public) (\(String(describing: started.duration(to: clock.now)), privacy: .public))")
            switch intent {
            case .closeTabs:
                return try await pickTabs(request, manager: context.manager)
            case .openBookmark:
                return try await openPage(request, context: context)
            case .reopenClosed:
                return try await reopenClosed(request, context: context)
            case .pageAction:
                return try await pickAction(request, context: context)
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
        // 温めてあればそれを使う。使い回すと前の問答が文脈に残るので、一度きり
        let session = warmSession ?? Self.makeIntentSession()
        warmSession = nil
        return try await self.respond(session, to: "お願い: \(request)",
                                      generating: TheodoreIntentAnswer.self).intent
    }

    private static func makeIntentSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            あなたはブラウザの操作係です。
            利用者のお願いを読んで、次のどれに当たるかを選んでください。
            closeTabs: 開いているタブを閉じるお願い。例「Apple 関連のタブを閉じて」「このタブを閉じて」「YouTube のタブを全部閉じて」
            openBookmark: サイトやページを開くお願い。例「GitHub を開いて」「天気のサイトを開いて」
            reopenClosed: 既に閉じたタブを、もう一度開くお願い。例「さっき閉じたタブを戻して」「GitHub のページ、もう一回開いて」「閉じちゃったページを開き直して」
            pageAction: 今のタブやブラウザへの操作のお願い。例「このタブをピン留めして」「リーダー表示にして」「消音して」「拡大して」「再読み込みして」「リロードして」「ページを更新して」「新しいタブを開いて」「設定を開いて」「PDF で書き出して」
            注意: 今開いているページを読み込み直す (再読み込み・リロード・更新) は pageAction です。reopenClosed ではありません。
            unsupported: それ以外のお願い
            """)
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
                「全部」「このタブ以外」と頼まれた時は、範囲 (scope) をそう答えれば、番号は選ばなくて構いません。
                """,
            request: request,
            heading: "タブ一覧",
            lines: lines,
            generating: TheodoreTabPick.self)

        // 「このタブ」「全部」「このタブ以外」は番号ではなく、こちらが知っている事実で決める。
        // 「全部」はこの窓の中だけ (他の窓まで畳むのは行き過ぎ)。
        // 空のロビーは閉じても新しいロビーが出来るだけなので、数に入れない
        switch answer.scope {
        case .current:
            Self.log.info("tabs: current tab")
            return proposeClosing(all.filter { $0.id == currentID }, request: request)
        case .all:
            let chosen = Self.windowTabs(all, except: nil)
            Self.log.info("tabs: all in this window, \(chosen.count, privacy: .public)")
            return proposeClosing(chosen, request: request)
        case .others:
            let chosen = Self.windowTabs(all, except: currentID)
            Self.log.info("tabs: others in this window, \(chosen.count, privacy: .public)")
            return proposeClosing(chosen, request: request)
        case .matching:
            break
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

    // この窓のタブ (空のロビーを除く)。except に渡したタブも除く
    private static func windowTabs(_ all: [TabSearchMatch], except excluded: UUID?) -> [TabSearchMatch] {
        all.filter { match in
            guard match.isCurrentWindow, match.id != excluded else { return false }
            guard let (_, tab) = TabManager.owner(of: match.id) else { return false }
            return !tab.isHome
        }
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
            return try await self.respond(session, to: prompt, generating: TheodoreTabMatch.self).matches
        } catch {
            // 言語の都合でも安全装置 (guardrail) でも、断られたら「当てはまらない」
            Self.log.error("verify tab failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // 開く。お願いに番地が書いてあればそこへ (隠し芸)、無ければ棚から探す。
    // 棚にも無ければ検索を勧める (pickBookmark の中で)
    private func openPage(_ request: String, context: DirectoryContext) async throws -> Outcome {
        let manager = context.manager
        if let url = Self.address(in: request) {
            Self.log.info("open: address in request")
            return .perform { Self.open(url, in: manager) }
        }
        return try await pickBookmark(request,
                                      manager: manager,
                                      bookmarks: context.bookmarks.bookmarks)
    }

    // 二段目 (開き直す)。4F の閉じたタブから選ばせて確かめる。
    // 見当たらなければ「開いて」と同じ流れ (番地 → 棚 → 検索) へ回す——
    // どちらも「そのページが見たい」というお願いには違いない
    private func reopenClosed(_ request: String, context: DirectoryContext) async throws -> Outcome {
        let manager = context.manager
        let closed = manager.recentlyClosedTabs
        guard !closed.isEmpty else {
            Self.log.info("reopen: nothing closed, falling back to open")
            return try await openPage(request, context: context)
        }

        // 番地が書いてあれば、ホストで突き合わせて一番新しい物を戻す
        if let url = Self.address(in: request), let host = url.host() {
            if let index = closed.firstIndex(where: {
                Self.host(URL(string: $0.url)?.host() ?? "", isWithin: host)
            }) {
                Self.log.info("reopen: by address")
                return .perform { manager.reopenClosed(newestIndex: index) }
            }
            return try await openPage(request, context: context)
        }

        let lines = closed.map { record in
            let host = URL(string: record.url)?.host() ?? ""
            let title = !record.title.isEmpty ? record.title
                : (record.url.isEmpty ? "新しいタブ" : record.url)
            return (title: title, note: host)
        }
        let answer: TheodoreClosedPick
        do {
            answer = try await pick(
                instructions: """
                    あなたはブラウザの案内係です。
                    一覧は利用者が最近閉じたタブで、上ほど新しく閉じたものです。
                    利用者が開き直したいページに当たるものを、一覧から一つだけ選んでください。
                    特定のページを指さず「さっき閉じたタブ」のように頼まれたら、一番上 (0) を選んでください。
                    当てはまるものが無ければ -1 を選んでください。
                    """,
                request: request,
                heading: "最近閉じたタブ",
                lines: lines,
                generating: TheodoreClosedPick.self)
        } catch {
            // 閉じたタブの題で断られても、棚と検索はまだ試せる
            Self.log.error("reopen: pick failed: \(String(describing: error), privacy: .public)")
            return try await openPage(request, context: context)
        }

        guard closed.indices.contains(answer.tabNumber) else {
            Self.log.info("reopen: none, falling back to open")
            return try await openPage(request, context: context)
        }
        let index = answer.tabNumber
        let record = closed[index]
        let host = URL(string: record.url)?.host() ?? ""
        let siteName = answer.siteName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 名前の無いお願い (「さっき閉じたタブ」) は、一番新しい物なら確かめるまでもない。
        // 名前があれば、題やホストに入っているかを見て、無ければ一件だけ見せて訊き直す
        if siteName.isEmpty {
            guard index == 0 else { return try await openPage(request, context: context) }
            Self.log.info("reopen: newest")
        } else if Self.mentions([record.title, host, record.url], siteName) {
            Self.log.info("reopen: matched by name")
        } else {
            let same = try await verifySameSite(request: request,
                                                siteName: siteName,
                                                title: record.title,
                                                host: host)
            Self.log.info("reopen: verified \(same, privacy: .public)")
            guard same else { return try await openPage(request, context: context) }
        }
        return .perform { manager.reopenClosed(newestIndex: index) }
    }

    // 二段目 (操作)。3F の一覧 (今のタブで意味のある物だけ) から一つ選ばせる。
    // 3F に操作を足せば、セオドアもそのまま使えるようになる
    private func pickAction(_ request: String, context: DirectoryContext) async throws -> Outcome {
        let all = Directory.actions(context)

        // 切り替えなら、名前の付いた選択肢で向きまで決める
        let toggleAnswer = try await classifyToggle(request)
        let toggle = toggleAnswer.toggle
        Self.log.info("action: toggle \(String(describing: toggle), privacy: .public)")
        // 音だけは今のタブに限らない。鳴っているタブと見ているタブは別なことが多い
        // 音とピン留めは、名指しがあれば今のタブ以外にも掛ける
        let tabAction: TheodoreTabAction?
        switch toggle {
        case .mute:   tabAction = .mute
        case .unmute: tabAction = .unmute
        case .pin:    tabAction = .pin
        case .unpin:  tabAction = .unpin
        default:      tabAction = nil
        }
        if let tabAction {
            return perTab(tabAction,
                          meansAll: toggleAnswer.meansAll,
                          siteName: toggleAnswer.siteName,
                          request: request,
                          manager: context.manager)
        }
        if let (key, opposite) = Self.keys(for: toggle) {
            if let entry = all.first(where: { $0.id == "action:" + key }) {
                let perform = entry.perform
                return .perform { perform() }
            }
            // 3F に逆向きしか無い = もうそうなっている
            if all.contains(where: { $0.id == "action:" + opposite }) {
                return .state(.message(request: request, text: TheodoreLines.alreadyDone))
            }
            // どちらも無い (リーダーに向かないページ、ロビー など)
            return .state(.message(request: request, text: TheodoreLines.cannotDoHere))
        }

        // それ以外の操作は一覧から選ばせる。
        // 切り替えは上で扱ったので一覧から外す (ここで向きを取り違えないように)
        let toggleIDs = Set(Self.togglePairs.flatMap { ["action:" + $0.0, "action:" + $0.1] })
        let actions = all.filter { !toggleIDs.contains($0.id) }
        // 英語の名前も添える。日本語の訳が硬い時の助けになる
        let lines = actions.map { entry in
            (title: entry.title,
             note: entry.keywords.first.flatMap { $0 == entry.title ? nil : $0 } ?? "")
        }
        let answer = try await pick(
            instructions: """
                あなたはブラウザの操作係です。
                一覧は、今のタブで使える操作です。
                利用者のしたいことに当たる操作を、一覧から一つだけ選んでください。
                当てはまるものが無ければ -1 を選んでください。
                """,
            request: request,
            heading: "操作一覧",
            lines: lines,
            generating: TheodoreActionPick.self)

        guard actions.indices.contains(answer.actionNumber) else {
            Self.log.info("action: none (\(answer.actionNumber, privacy: .public))")
            return .state(.message(request: request, text: TheodoreLines.cannotDoHere))
        }
        let entry = actions[answer.actionNumber]
        // 名前の一致では決めない。言い方の違い (「音消して」と「タブをミュート」) は
        // モデルに判断させ、全く別の操作を選んでいたら断る
        let fits = try await verifyAction(request: request, wanted: answer.wanted, action: entry.title)
        Self.log.info("action: \(entry.id, privacy: .public), verified \(fits, privacy: .public)")
        guard fits else {
            return .state(.message(request: request, text: TheodoreLines.cannotDoHere))
        }

        // タブを閉じるのだけは、閉じる系と同じく提案を見せる
        if entry.id == "action:Close Tab" {
            let current = TabSearch.matches(query: "", from: context.manager)
                .filter { $0.id == context.manager.selectedTab?.id }
            return proposeClosing(current, request: request)
        }
        let perform = entry.perform
        return .perform { perform() }
    }

    // 一つだけ見せて、その操作でしたいことが叶うかを答えさせる。
    //
    // 初めは「逆向きなら false」を強く言い聞かせていたが、厳し過ぎて
    // 「音消して」→「タブをミュート」まで断っていた (2026-11 実測)。
    // 向きのある切り替えは先に TheodoreToggle で扱うので、ここは言い換えに寛容にする
    private func verifyAction(request: String, wanted: String, action: String) async throws -> Bool {
        let session = LanguageModelSession(instructions: """
            あなたはブラウザの操作係です。
            利用者のしたいことと、ブラウザの操作を一つ見て、その操作でしたいことが叶うかを判定してください。
            言い方が違っても、同じことをする操作なら true です。
            例:「音消して」と「タブをミュート」、「リーダーモードを解除して」と「リーダーを隠す」、「大きくして」と「拡大」はどれも true です。
            全く別のことをする操作なら false です。
            """)
        let prompt = """
            お願い: \(request)
            したいこと: \(wanted)
            操作: \(action)
            """
        do {
            return try await self.respond(session, to: prompt, generating: TheodoreActionMatch.self).matches
        } catch {
            Self.log.error("verify action failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // 3F の切り替えの組 (行の鍵)。一覧から選ばせる時はこれを外す
    private static let togglePairs: [(String, String)] = [
        ("Pin Tab", "Unpin Tab"),
        ("Mute Tab", "Unmute Tab"),
        ("Show Reader", "Hide Reader"),
        ("Float Tab", "Return Floating Tab"),
        ("Show Bookmarks Bar", "Hide Bookmarks Bar"),
        ("Show Downloads", "Hide Downloads"),
    ]

    // 切り替え → (したい向きの行の鍵, 逆向きの行の鍵)
    private static func keys(for toggle: TheodoreToggle) -> (String, String)? {
        switch toggle {
        case .pin:               ("Pin Tab", "Unpin Tab")
        case .unpin:             ("Unpin Tab", "Pin Tab")
        case .mute:              ("Mute Tab", "Unmute Tab")
        case .unmute:            ("Unmute Tab", "Mute Tab")
        case .showReader:        ("Show Reader", "Hide Reader")
        case .hideReader:        ("Hide Reader", "Show Reader")
        case .floatTab:          ("Float Tab", "Return Floating Tab")
        case .returnFloatingTab: ("Return Floating Tab", "Float Tab")
        case .showBookmarksBar:  ("Show Bookmarks Bar", "Hide Bookmarks Bar")
        case .hideBookmarksBar:  ("Hide Bookmarks Bar", "Show Bookmarks Bar")
        case .showDownloads:     ("Show Downloads", "Hide Downloads")
        case .hideDownloads:     ("Hide Downloads", "Show Downloads")
        case .other:             nil
        }
    }

    // 音を消す / 戻す相手を決める。
    //   消す: 鳴っているタブ (ミュートしていない物)
    //   戻す: ミュート中のタブ
    // 名指しがあれば、その名前が題かホストに入っている物に絞る。
    // 名指しが無ければ、今のタブが当てはまればそれ、でなければ当てはまる物全部。
    // 一枚に決まればすぐ、何枚もあれば札を出して確かめる
    // 音・ピン留めの相手を決める。
    //   消す: 鳴っているタブ (ミュートしていない物)   戻す: ミュート中のタブ
    //   留める: 留めていないタブ                     外す: 留めてあるタブ
    // 「全部」なら、ピン留めはこの窓のタブ全部、音は全ての窓のタブ全部 (名指しは見ない)。
    // 名指しがあれば、その名前が題かホストに入っている物に絞る (窓をまたいで探す)。
    // 名指しが無ければ——
    //   音: 今のタブが当てはまればそれ、でなければ当てはまる物全部
    //       (鳴っているタブと見ているタブは別なことが多い)
    //   ピン留め: 今のタブだけ
    // 一枚に決まればすぐ、何枚もあれば札を出して確かめる
    private func perTab(_ action: TheodoreTabAction,
                        meansAll: Bool,
                        siteName: String,
                        request: String,
                        manager: TabManager) -> Outcome {
        // 名指しは、お願いの文に本当に書いてある時だけ信じる。
        // 「音消して」だけでも、言いつけの例に引かれて "YouTube" と答えることがあった
        // (2026-11 実測：名指しの無いお願いで named true)。
        // 鵜呑みにすると、鳴っているのが Spotify の時に見当違いの答えになる
        // 「全部」も同じく、お願いに「全」「すべて」等が本当に書いてある時だけ信じる
        let wantsAll = meansAll && Self.allWords.contains { request.lowercased().contains($0) }
        let trimmed = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (!wantsAll && Self.mentions([request], trimmed)) ? trimmed : ""
        // 並びと範囲はタブ検索と同じ (普通の窓とプライベートは互いに見えない)
        var all: [(match: TabSearchMatch, tab: Tab)] = TabSearch.matches(query: "", from: manager)
            .compactMap { match in TabManager.owner(of: match.id).map { (match: match, tab: $0.tab) } }
        // ピン留めの「全部」はこの窓の中だけ (閉じる時の「全部」と揃える)
        if wantsAll && !action.isAudio {
            all = all.filter { $0.match.isCurrentWindow }
        }
        let named = name.isEmpty ? all : Self.named(all, name)
        let fits = named.filter { Self.fits(action, $0.tab) }

        var chosen = fits
        if !wantsAll, name.isEmpty, let current = manager.selectedTab {
            if action.isAudio {
                if let mine = fits.first(where: { $0.tab === current }) { chosen = [mine] }
            } else {
                chosen = fits.filter { $0.tab === current }
            }
        }
        Self.log.info("tabs: \(String(describing: action), privacy: .public), all \(wantsAll, privacy: .public), named \(!name.isEmpty, privacy: .public), candidates \(chosen.count, privacy: .public)")

        guard !chosen.isEmpty else {
            // 名指しのサイトがどこにも開いていない
            if !name.isEmpty && named.isEmpty {
                return .state(.message(request: request, text: TheodoreLines.noMatchingTabs))
            }
            // 相手は居るが、もうそうなっている
            return .state(.message(request: request, text: TheodoreLines.alreadyDone))
        }
        if chosen.count == 1 {
            let id = chosen[0].match.id
            return .perform { Self.apply(action, [id]) }
        }
        let items = chosen.map {
            TheodoreTabItem(id: $0.match.id, title: $0.match.title,
                            host: $0.match.host, favicon: $0.match.favicon)
        }
        return .state(.proposeTabs(request: request, tabs: items, action: action))
    }

    // 「全部」を表す言葉。モデルの meansAll を裏付けるのに使う
    private static let allWords = ["全", "すべて", "みんな", "all", "every"]

    // その操作を掛ける意味があるタブか (もうそうなっている物は外す)
    private static func fits(_ action: TheodoreTabAction, _ tab: Tab) -> Bool {
        switch action {
        case .mute:   tab.isPlayingAudio && !tab.isMuted
        case .unmute: tab.isMuted
        case .pin:    !tab.isPinned
        case .unpin:  tab.isPinned
        }
    }

    // 名指しに当たるタブ。まず名前をそのまま探し、
    // 見つからなければ語に分けて全部の語が入っている物を探す
    // ("Vapor ドキュメント" と言われて、題が "Vapor のドキュメント" の時など)
    private static func named(_ all: [(match: TabSearchMatch, tab: Tab)],
                              _ name: String) -> [(match: TabSearchMatch, tab: Tab)] {
        let whole = all.filter { mentions([$0.match.title, $0.match.host], name) }
        if !whole.isEmpty { return whole }
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
        guard words.count > 1 else { return [] }
        return all.filter { entry in
            words.allSatisfy { mentions([entry.match.title, entry.match.host], $0) }
        }
    }

    // 決めた向きに揃える。もうそうなっている物には触らない
    private static func apply(_ action: TheodoreTabAction, _ ids: [UUID]) {
        for id in ids {
            guard let (owner, tab) = TabManager.owner(of: id) else { continue }
            switch action {
            case .mute:   if !tab.isMuted { tab.toggleMute() }
            case .unmute: if tab.isMuted { tab.toggleMute() }
            case .pin:    owner.setPinned(tab, true)
            case .unpin:  owner.setPinned(tab, false)
            }
        }
    }

    // お願いが切り替えのどれに当たるか
    private func classifyToggle(_ request: String) async throws -> TheodoreToggleAnswer {
        let session = LanguageModelSession(instructions: """
            あなたはブラウザの操作係です。
            利用者のお願いが、次の切り替えのどれに当たるかを選んでください。
            言い方が違っても、したいことが同じなら当てはまります。
            向き (付ける⇔外す、表示する⇔やめる) を取り違えないよう、特に「解除」「やめて」「外して」「戻して」に気を付けてください。
            pin: タブをピン留めする。例「ピン留めして」「このタブを固定して」「GitHub のタブをピン留めして」
            unpin: ピン留めを外す。例「ピン留めを外して」「ピン留め解除」「固定をやめて」「GitHub のタブのピン留めを外して」「全タブのピン留めを外して」
            mute: タブの音を消す。例「音消して」「ミュートして」「静かにして」「黙らせて」「YouTube の音を消して」
            unmute: タブの音を戻す。例「音戻して」「ミュート解除」「音を出して」「YouTube の音戻して」
            showReader: リーダー表示にする。例「リーダーモードにして」「リーダー表示で読みたい」
            hideReader: リーダー表示をやめて、元のページの表示に戻す。例「リーダーモードを解除して」「リーダーをやめて」「リーダー表示を閉じて」
            floatTab: タブを小窓に浮かべる。例「小窓にして」「ピクチャ・イン・ピクチャにして」
            returnFloatingTab: 小窓をタブに戻す。例「小窓を戻して」「小窓をやめて」
            showBookmarksBar: ブックマークバーを表示する
            hideBookmarksBar: ブックマークバーを隠す
            showDownloads: ダウンロードの棚を表示する
            hideDownloads: ダウンロードの棚を隠す
            other: 上のどれでもない操作。例「再読み込みして」「拡大して」「印刷して」「新しいタブを開いて」「設定を開いて」
            """)
        return try await self.respond(session, to: "お願い: \(request)",
                                      generating: TheodoreToggleAnswer.self)
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
        let answer: TheodoreBookmarkPick
        do {
            answer = try await pick(
                instructions: """
                    あなたはブックマークの案内係です。
                    利用者が開きたいサイトに最も合うブックマークを、一覧から一つだけ選んでください。
                    当てはまるものが無ければ -1 を選んでください。
                    """,
                request: request,
                heading: "ブックマーク一覧",
                lines: lines,
                generating: TheodoreBookmarkPick.self)
        } catch {
            // 窓あふれは本当に手に余るので、いつも通り詫びる
            if let error = error as? LanguageModelSession.GenerationError,
               case .exceededContextWindowSize = error { throw error }
            Self.log.error("bookmark: pick failed: \(String(describing: error), privacy: .public)")
            return offerSearch(request, query: request, manager: manager)
        }

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
            let same = try await verifySameSite(request: request,
                                                siteName: answer.siteName,
                                                title: bookmark.title,
                                                host: URL(string: bookmark.url)?.host() ?? "")
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

    // 一組だけを見せて、同じサイトかを答えさせる (棚のブックマーク・閉じたタブ)。
    // 言語の都合で断られたら「違う」として扱う (開き違いよりは断る方がまし)
    private func verifySameSite(request: String,
                                siteName: String,
                                title: String,
                                host: String) async throws -> Bool {
        let session = LanguageModelSession(instructions: """
            あなたはブラウザの案内係です。
            利用者が開きたいサイトと、候補のページが同じサイトを指しているかを判定してください。
            名前が似ているだけの別のサイトや、同じ分野の別のサイトなら false です。
            """)
        let prompt = """
            お願い: \(request)
            開きたいサイト: \(siteName)
            候補: \(ModelLanguage.sanitize(title)) (\(host))
            """
        do {
            return try await self.respond(session, to: prompt, generating: TheodoreSameSite.self).isSame
        } catch {
            // 言語の都合でも安全装置 (guardrail) でも、断られたら「違う」
            Self.log.error("verify site failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // モデルへの問い合わせは全てここを通す。一回終わるごとに針を一段上げる
    private func respond<T: Generable>(_ session: LanguageModelSession,
                                       to prompt: String,
                                       generating type: T.Type) async throws -> T {
        defer { steps += 1 }
        return try await session.respond(to: prompt,
                                         generating: type,
                                         options: Self.options).content
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
            return try await self.respond(session, to: prompt, generating: type)
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
