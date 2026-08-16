//
//  PopupBlocker.swift
//  Skyscraper
//
//  window.open() で開かれるポップアップの門番。
//
//  WKWebView は既定で「ユーザー操作を伴わない window.open()」を弾いている
//  （javaScriptCanOpenWindowsAutomatically が false）。
//  だから createWebViewWith まで届くのは、クリックに便乗して開かれたものだ。
//  リンクを踏んだ結果（target="_blank"）とは navigationType で区別できる。
//
//  ただし OAuth のログイン窓、決済窓、共有ボタンも同じ形をしている。
//  黙って捨てると、利用者からは「ボタンが壊れている」ようにしか見えない。
//  だからブロックしたことを必ず知らせて、その場で開き直せるようにする。
//

import Foundation

@MainActor
final class PopupAllowList {
    static let shared = PopupAllowList()

    private let storageKey = "skyscraper.popupAllowList.v1"
    // ポップアップを許したページの host（開かれる先ではなく、開く側）
    private var hosts: Set<String>

    private init() {
        hosts = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    func isAllowed(_ host: String) -> Bool {
        !host.isEmpty && hosts.contains(host)
    }

    // 許可一覧の鍵。通常はページの host。
    //
    // file:// や about: は host を持たない。ここが空文字のままだと
    // allow() が何も記録できず、isAllowed() も永久に false を返すので、
    // 「このサイトでは常に許可」を押しても次からまた止まる。
    // host が無い場合は、スキームとパスから代わりの鍵を作る。
    // ローカルファイルは一枚単位の鍵になる（同じフォルダの別の
    // HTML までまとめて許さない）
    static func originKey(for url: URL?) -> String {
        guard let url else { return "" }
        if let host = url.host(), !host.isEmpty { return host }
        guard let scheme = url.scheme, !scheme.isEmpty else { return "" }
        return "\(scheme):\(url.path(percentEncoded: false))"
    }

    func allow(_ host: String) {
        guard !host.isEmpty else { return }
        hosts.insert(host)
        UserDefaults.standard.set(Array(hosts), forKey: storageKey)
    }

    // 一件だけ取り消す（サイト情報から）。
    // 設定画面の reset() は全部忘れるので、一枚のために
    // 他のサイトの許可まで巻き添えにする理由は無い
    func revoke(_ host: String) {
        guard hosts.remove(host) != nil else { return }
        UserDefaults.standard.set(Array(hosts), forKey: storageKey)
    }

    func reset() {
        hosts.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.synchronize()
    }
}

// ブロックしたポップアップ一件ぶん
struct BlockedPopup: Identifiable {
    let id = UUID()
    let url: String
}
