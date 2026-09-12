//
//  PrivateBrowsing.swift
//  Skyscraper
//
//  プライベートウィンドウのデータの置き場を受け持つ。
//
//  ── なぜ一つを使い回すのか ──
//  WKWebsiteDataStore.nonPersistent() は呼ぶたびに別の実体を返す。
//  窓ごとに作ると、プライベートウィンドウを二枚開いた時に
//  片方でログインしても、もう片方では他人のままになる。
//  Safari も Chrome も「プライベートの世界は一つ」なので、それに倣う。
//
//  ── どこにも書かれない ──
//  非永続ストアは Cookie もキャッシュもディスクに触れない。
//  アプリを終えれば跡形も無く消える。
//  それでも最後の一枚を閉じた時点で中身を捨てるのは、
//  「閉じたのにプロセスの中には残っている」のが筋の通らない話だからだ。
//

import Foundation
import WebKit

@MainActor
enum PrivateBrowsing {
    // 生きている置き場。誰も使っていなければ nil になる。
    // 強く持つのは各 TabManager の方で、こちらは見張っているだけだ
    private static weak var shared: WKWebsiteDataStore?

    // 今この置き場を使っている窓の数
    private static var users = 0

    // 使い始める。既にあるならそれを渡す
    static func acquire() -> WKWebsiteDataStore {
        users += 1
        if let shared { return shared }
        let fresh = WKWebsiteDataStore.nonPersistent()
        shared = fresh
        print("PrivateBrowsing: opened a new non-persistent store")
        return fresh
    }

    // 使い終わる。最後の一人が抜けたら中身を捨てる
    static func release(_ store: WKWebsiteDataStore?) {
        users = max(0, users - 1)
        guard users == 0, let store else { return }

        // ページのデータとは別に、こちらがメモリで持っていた許可の記憶も捨てる。
        // 「プライベートで許した」が次のプライベートセッションに持ち越されては困る
        GeolocationStore.shared.forgetSession()
        MediaPermissionStore.shared.forgetSession()

        // 呼ぶ側（窓）はもう死んでいるので、完了は待たない
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {
            print("PrivateBrowsing: the last private window closed; data discarded")
        }
    }
}
