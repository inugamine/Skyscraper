//
//  AddressSuggestions.swift
//  Skyscraper
//
//  アドレスバーの候補を組み立てる。
//
//  出どころは手元にあるものだけ——ブックマークと、今開いているタブ。
//  閲覧履歴は取らないので候補にも出せないし、検索エンジンの
//  suggest API も叩かない（打鍵のたびに未確定の入力を外へ送ることになる）。
//  つまりこの機能は、動いている間ネットワークに一切触れない。
//

import Foundation

// 候補一件ぶん。
// kind が「押したら何が起きるか」を持ち、title / detail は見せ方だけを持つ
struct AddressSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        // 打った文字をそのまま住所として開く。
        // 中身は整形前の入力そのもの——表示用に整えた文字列を渡すと、
        // 利用者が明示した http:// やポート番号が落ちて別の場所へ行く
        case navigate(String)
        // 打った文字を検索語として投げる
        case search(String)
        // ブックマークを開く
        case bookmark(String)
        // 既に開いているタブへ移る
        case openTab(UUID)
    }

    let kind: Kind
    let title: String
    let detail: String

    var id: String {
        switch kind {
        case .navigate(let text): return "navigate:\(text)"
        case .search(let text):   return "search:\(text)"
        case .bookmark(let url):  return "bookmark:\(url)"
        case .openTab(let id):    return "tab:\(id.uuidString)"
        }
    }

    var symbol: String {
        switch kind {
        case .navigate: return "arrow.up.right"
        case .search:   return "magnifyingglass"
        case .bookmark: return "star"
        // 開いているタブは六角形。縦タブの意匠と揃える
        case .openTab:  return "hexagon"
        }
    }
}

// タブを候補に載せるための、最小限の写し。
// Tab そのもの（@MainActor の ObservableObject）を持ち込むと
// 並べ替えのためだけに UI の都合を引き受けることになる
struct TabCandidate {
    let id: UUID
    let title: String
    let url: String
}

enum AddressSuggestions {
    // 一覧に出す上限。先頭の「入力の解釈」を含めた総数
    static let limit = 8

    // Tab.interpret を借りるので、Tab と同じ MainActor に乗る。
    // 呼ぶのはアドレスバーを描いている View だけなので実害はない
    @MainActor
    static func build(query: String,
                      bookmarks: [Bookmark],
                      tabs: [TabCandidate]) -> [AddressSuggestion] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return [] }

        var result: [AddressSuggestion] = []

        // ── 先頭は必ず「Return を押したら何が起きるか」 ──
        //
        // 判断は Tab.interpret に任せる。ここで同じ規則を書き直すと、
        // 一覧の一行目と実際の遷移先がいつか食い違う
        switch Tab.interpret(raw) {
        case .file(let url):
            result.append(AddressSuggestion(kind: .navigate(raw),
                                            title: url.path,
                                            detail: String(localized: "Open File")))
        case .web(let url):
            result.append(AddressSuggestion(kind: .navigate(raw),
                                            title: display(url.absoluteString),
                                            detail: String(localized: "Open Address")))
        case .search(let text):
            result.append(AddressSuggestion(kind: .search(text),
                                            title: text,
                                            detail: String(localized: "Search with Google")))
        case .none:
            break
        }

        // 一行目が連れて行く先。同じ場所を指すブックマークは省く
        let target: String? = {
            if case .navigate(let text) = result.first?.kind {
                return Tab.resolveURL(from: text).map { normalized($0.absoluteString) }
            }
            return nil
        }()

        let needle = normalized(raw)

        // ── ブックマーク ──
        let hits = bookmarks.enumerated().compactMap { index, bm -> (Rank, AddressSuggestion)? in
            guard normalized(bm.url) != target,
                  let rank = rank(needle: needle, title: bm.title, url: bm.url, order: index)
            else { return nil }
            return (rank, AddressSuggestion(kind: .bookmark(bm.url),
                                            title: bm.title.isEmpty ? display(bm.url) : bm.title,
                                            detail: display(bm.url)))
        }

        // ── 開いているタブ ──
        //
        // 同じ場所でも「開く」と「そのタブへ移る」は別の行いなので、
        // 一行目と重なっても省かない。
        // まだ何も読み込んでいないタブ（新規タブ）は URL が空なので落ちる
        let switches = tabs.enumerated().compactMap { index, t -> (Rank, AddressSuggestion)? in
            guard !t.url.isEmpty,
                  let rank = rank(needle: needle, title: t.title, url: t.url, order: index)
            else { return nil }
            return (rank, AddressSuggestion(kind: .openTab(t.id),
                                            title: t.title.isEmpty ? display(t.url) : t.title,
                                            detail: String(localized: "Switch to Tab")))
        }

        let ranked = (hits + switches)
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        result.append(contentsOf: ranked.prefix(limit - result.count))
        return result
    }

    // MARK: - 並べ替え

    // 小さいほど上に出る。
    // tier で大きく分け、同じ tier の中は penalty、最後は元の並び順で決める
    // （順位が入力のたびに揺れると、狙って選べない）
    private struct Rank: Comparable {
        let tier: Int
        let penalty: Int
        let order: Int

        static func < (a: Rank, b: Rank) -> Bool {
            (a.tier, a.penalty, a.order) < (b.tier, b.penalty, b.order)
        }
    }

    // 一致の強さを測る。かすりもしなければ nil
    private static func rank(needle: String, title: String, url: String, order: Int) -> Rank? {
        guard !needle.isEmpty else { return nil }
        let host = normalized(url)
        let name = title.lowercased()

        // 住所の頭から一致：一番強い。
        // 同じ強さなら短い方を上にして、深い階層より入口を先に出す
        if host.hasPrefix(needle) {
            return Rank(tier: 0, penalty: host.count, order: order)
        }
        // 題名の頭から一致
        if name.hasPrefix(needle) {
            return Rank(tier: 1, penalty: name.count, order: order)
        }
        // 住所の途中で一致：頭に近いほど上
        if let found = host.range(of: needle) {
            return Rank(tier: 2, penalty: host.distance(from: host.startIndex, to: found.lowerBound),
                        order: order)
        }
        // 題名の途中で一致
        if let found = name.range(of: needle) {
            return Rank(tier: 3, penalty: name.distance(from: name.startIndex, to: found.lowerBound),
                        order: order)
        }
        return nil
    }

    // MARK: - 文字列の均し

    // 見比べるための形に均す。
    // "https://www.Example.com/" と "example.com" を同じものとして扱いたい
    static func normalized(_ url: String) -> String {
        var text = url.lowercased().trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
            break
        }
        if text.hasPrefix("www.") {
            text.removeFirst(4)
        }
        if text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    // 画面に出すための形。
    // 均しと違って大文字小文字は保つ（パスやクエリの意味が変わるため）
    private static func display(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
            break
        }
        if text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}
