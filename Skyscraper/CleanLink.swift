//
//  CleanLink.swift
//  Skyscraper
//
//  リンクに付いた追跡用の札 (utm_ や fbclid など) を剥がす。
//
//  剥がす場面は三つ:
//  - 右クリックの「Copy Clean Link」(リンクの上で)
//  - Edit メニューの「Copy Clean Link」(⇧⌘C、今見ているページ)
//  - ページを開く時 (設定で切れる。Tab の decidePolicyFor から呼ぶ)
//
//  剥がすのは「誰がどこから来たか」を数えるためだけの札に限る。
//  ページの中身を決める引数 (検索語、動画の再生位置 t= など) には触らない。
//  一覧に無い札は残る——取りこぼしは許すが、ページを壊すことは許さない作りだ。
//
//  開く時に剥がす場合、新しいタブ・プライベート・別ウインドウ・target=_blank の
//  どの道で開いても、最後は開いた先のタブの decidePolicyFor を通る。
//  だから呼び口はそこ一つで足りる
//

import AppKit
import Foundation
import WebKit

enum CleanLink {

    // 開く時にも剥がすか。既定は入
    static let enabledKey = "skyscraper.cleanLinks"

    static var stripsOnOpen: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // 頭がこれで始まる札は全部剥がす
    private static let prefixes = ["utm_"]

    // どのサイトでも剥がす札。広告網とメール配信網のクリック番号
    private static let everywhere: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid",
        "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "igshid", "igsh",
        "mc_cid", "mc_eid",
        "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp",
        "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv",
        "rb_clickid", "_openstat", "wickedid",
    ]

    // そのサイトでだけ剥がす札。
    // 他所では別の意味で使われうる名前なので、ホスト (と道) を絞る
    private struct Rule {
        let hosts: [String]
        let names: Set<String>
        // 指定があれば、道にこの文字列を含む時だけ効く
        var pathContains: String? = nil

        func matches(host: String, path: String) -> Bool {
            guard hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                return false
            }
            if let pathContains, !path.contains(pathContains) { return false }
            return true
        }
    }

    private static let rules: [Rule] = [
        // 共有ボタンが付ける「誰が共有したか」の印。再生には関係ない
        Rule(hosts: ["youtube.com", "youtu.be"], names: ["si"]),
        Rule(hosts: ["spotify.com"], names: ["si"]),
        // X の共有リンクの s= / t= は投稿の頁でだけ剥がす。
        // 検索の頁などでは別の役目を持つことがあるため
        Rule(hosts: ["twitter.com", "x.com"], names: ["ref_src", "ref_url"]),
        Rule(hosts: ["twitter.com", "x.com"], names: ["s", "t"], pathContains: "/status/"),
    ]

    // 剥がす札があれば剥がした URL を、無ければ nil を返す。
    //
    // 札は percentEncodedQueryItems で扱う。queryItems で読み書きすると
    // 残す側の札まで符号化し直され、サイトによっては別の宛先になる
    static func cleaned(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems,
              !items.isEmpty
        else { return nil }

        let host = (components.host ?? "").lowercased()
        let path = components.percentEncodedPath
        let siteNames = rules
            .filter { $0.matches(host: host, path: path) }
            .reduce(into: Set<String>()) { $0.formUnion($1.names) }

        let kept = items.filter { !shouldStrip($0.name, siteNames: siteNames) }
        guard kept.count < items.count else { return nil }

        // 全部剥がれたら ? ごと消す
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url
    }

    private static func shouldStrip(_ rawName: String, siteNames: Set<String>) -> Bool {
        let name = (rawName.removingPercentEncoding ?? rawName).lowercased()
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return everywhere.contains(name) || siteNames.contains(name)
    }

    // 剥がしてからクリップボードへ。剥がす物が無ければそのまま入れる。
    // 文字列と URL の両方の形で置くので、どちらを欲しがる相手にも貼れる
    static func copy(_ url: URL) {
        let text = (cleaned(url) ?? url).absoluteString
        let board = NSPasteboard.general
        board.declareTypes([.string, .URL], owner: nil)
        board.setString(text, forType: .string)
        board.setString(text, forType: .URL)
    }

    // 今見ているページ用。ロビー (新規タブ) や about: の頁では何もしない。
    //
    // URL を取り出すのをこちらでやるのは、メニュー側 (SkyscraperApp.swift) が
    // WebKit を読み込んでおらず、webView.url に触れないから
    @MainActor
    static func copyPage(of tab: Tab?) {
        guard let url = tab?.webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        copy(url)
    }
}
