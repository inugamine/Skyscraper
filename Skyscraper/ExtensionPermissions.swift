//
//  ExtensionPermissions.swift
//  Skyscraper
//
//  拡張機能に何を許したかを預かる係と、それを人に見せる形に整える係。
//
//  ── なぜ記憶が要るのか ──
//  拡張の読み込みは起動時（WebExtensionManager.loadAll）に走る。
//  そこで毎回許諾を訊いたら、起動のたびにダイアログが出ることになる。
//  一度答えたら覚える。覚えていないものだけを「保留」にして、
//  一覧から利用者の都合で確認してもらう。
//
//  ── 保留という状態 ──
//  未確認の拡張は controller に載せない。載せてから訊くのでは遅い——
//  載せた時点で DNR もコンテンツスクリプトも動き始める。
//  訊く前に動いているのでは、訊く意味が無い。
//
//  ── 既にあるものの引き継ぎ ──
//  この仕組みを入れる前から入っていた拡張（uBOL）は、
//  初回だけ許可済みとして書き込む。利用者が自分で入れたもので、
//  現に動いている。起動したら突然「確認してください」と出るのは筋が悪い。
//

import Foundation
import WebKit

// MARK: - 許諾の記憶

@MainActor
enum ExtensionPermissionStore {

    // 拡張フォルダ名 → 許可したか。
    // 鍵が無い＝まだ訊いていない（保留）
    private static let decisionsKey = "skyscraper.extensions.permissions.v1"
    // プライベートウィンドウでも働かせるか。拡張ごとに持つ
    private static let privateDataKey = "skyscraper.extensions.privateData.v1"
    // 引き継ぎを済ませたかの目印。一度だけ立てる
    private static let grandfatheredKey = "skyscraper.extensions.grandfathered"

    private static var decisions: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: decisionsKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: decisionsKey) }
    }

    private static var privateData: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: privateDataKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: privateDataKey) }
    }

    // MARK: - 読み出し

    // この拡張について覚えていること。nil なら未確認
    static func decision(for id: String) -> Bool? {
        decisions[id]
    }

    // プライベートウィンドウでも働かせるか。
    //
    // 既定は入。ここを切ると、拡張にはプライベートの窓もタブも一切見えず、
    // uBOL の遮断が黙って効かなくなる。
    // 「プライベートにした途端に広告が戻る」は、使う側から見れば故障と同じだ
    static func allowsPrivateData(for id: String) -> Bool {
        privateData[id] ?? true
    }

    // MARK: - 書き込み

    static func record(id: String, allowed: Bool, privateData allowsPrivate: Bool) {
        var all = decisions
        all[id] = allowed
        decisions = all

        var priv = privateData
        priv[id] = allowsPrivate
        Self.privateData = priv
    }

    static func setAllowsPrivateData(_ allows: Bool, for id: String) {
        var priv = privateData
        priv[id] = allows
        privateData = priv
    }

    // その拡張の記憶を丸ごと忘れる。
    // 削除した拡張の分を残しておく理由が無い
    static func forget(id: String) {
        var all = decisions
        all.removeValue(forKey: id)
        decisions = all

        var priv = privateData
        priv.removeValue(forKey: id)
        privateData = priv
    }

    // MARK: - 引き継ぎ

    // この仕組みを入れる前から入っていた分を、許可済みとして書き込む。
    //
    // loadAll の冒頭で、見つかったフォルダ名の一覧を渡して一度だけ呼ぶ。
    // 二度目からは何もしない——でないと、一度「拒否」した拡張が
    // 次の起動で許可済みに戻ってしまう
    static func grandfatherIfNeeded(ids: [String]) {
        guard !UserDefaults.standard.bool(forKey: grandfatheredKey) else { return }
        UserDefaults.standard.set(true, forKey: grandfatheredKey)

        var all = decisions
        for id in ids where all[id] == nil {
            all[id] = true
        }
        decisions = all
    }
}

// MARK: - 権限を人に見せる形にする

// 拡張が要求している権限を、許諾シートに並べられる形へ均す。
//
// 対訳は用意しない。permissions の名前は仕様で決まった機械的な綴りで、
// 数も増え続ける。全部に訳を当てると、知らない名前が来た時に
// 黙って消える実装になりがちだ——それは一番やってはいけない。
// 綴りはそのまま出し、重いものにだけ一言添える
enum ExtensionPermissionDigest {

    struct Item: Identifiable {
        let id: String
        // 画面に出す綴り
        let name: String
        // 添える一言。無ければ nil
        let note: String?
        // 重い権限か（印を付けて目立たせる）
        let isBroad: Bool
    }

    // 全てのサイトに届くパターン。
    // これが入っていると、拡張はどこを見ていても中身に触れる。
    //
    // nonisolated なのは contains(where:) のクロージャから呼ぶため。
    // 文字列を見るだけで状態には触らない
    nonisolated private static func isAllSites(_ pattern: String) -> Bool {
        let text = pattern.lowercased()
        return text == "<all_urls>" || text == "*://*/*"
            || text.hasPrefix("*://*/") || text == "http://*/*" || text == "https://*/*"
    }

    // 重い権限。ここに挙げたものだけ印を付ける
    private static let broadPermissions: Set<String> = [
        "scripting", "tabs", "webRequest", "webRequestBlocking",
        "cookies", "history", "bookmarks", "downloads", "management",
        "nativeMessaging", "debugger", "proxy", "privacy",
    ]

    private static func note(for permission: String) -> String? {
        switch permission {
        case "scripting":
            return String(localized: "Can run its own code in pages.")
        case "tabs":
            return String(localized: "Can see the address and title of every tab.")
        case "cookies":
            return String(localized: "Can read and change cookies.")
        case "history":
            return String(localized: "Can read and change your browsing history.")
        case "bookmarks":
            return String(localized: "Can read and change your bookmarks.")
        case "downloads":
            return String(localized: "Can start and manage downloads.")
        case "nativeMessaging":
            return String(localized: "Can talk to programs outside Skyscraper.")
        case "debugger", "proxy":
            return String(localized: "Can change how Skyscraper connects to sites.")
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess":
            return String(localized: "Can block and change network requests.")
        default:
            return nil
        }
    }

    // 権限の一覧。要求と任意の両方を並べる。
    //
    // 任意（optional）も混ぜるのは、今の読み込みがどちらも通しているからだ。
    // 通すものを全部見せないと、訊いた意味が無くなる
    static func permissions(of ext: WKWebExtension) -> [Item] {
        // Permission は String そのものではなく rawValue に綴りを持つ型。
        // 並べ替えも照合も綴りでやるので、先に抜いておく
        let all = ext.requestedPermissions.union(ext.optionalPermissions).map(\.rawValue)
        return all.sorted().map { permission in
            Item(id: "perm:\(permission)",
                 name: permission,
                 note: note(for: permission),
                 isBroad: broadPermissions.contains(permission))
        }
    }

    // 触れるサイトの一覧。
    //
    // 全サイトに届くパターンが一つでもあれば、個別の綴りを並べる意味は無い——
    // 一行にまとめて、それが全部を意味することをはっきり書く
    static func sites(of ext: WKWebExtension) -> [Item] {
        let patterns = ext.requestedPermissionMatchPatterns
            .union(ext.optionalPermissionMatchPatterns)
            .map(\.string)

        guard !patterns.isEmpty else { return [] }

        if patterns.contains(where: isAllSites) {
            return [Item(id: "site:all",
                         name: String(localized: "All websites"),
                         note: String(localized: "Can read and change the content of every page you visit."),
                         isBroad: true)]
        }

        return patterns.sorted().map { pattern in
            Item(id: "site:\(pattern)", name: pattern, note: nil, isBroad: false)
        }
    }
}
