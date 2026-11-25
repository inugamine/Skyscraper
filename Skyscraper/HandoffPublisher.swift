//
//  HandoffPublisher.swift
//  Skyscraper
//
//  今見ているページを、同じ Apple Account の iPad (中二階 Mezzanine) に知らせる係 (Handoff)。
//  iPad の Dock に Mezzanine の印が出て、押すとそのページが Mezzanine の新しいタブで開く。
//  逆向き (iPad で読んでいたページを Mac で開く) の受け口は IncomingURL.swift の AppDelegate。
//
//  ── 仕組み ──
//  同じ開発チームのアプリどうしは、同じ「活動の種類」(NSUserActivity の activityType) を名乗れば、
//  端末をまたいで今の活動を受け渡せる。種類は Mezzanine と共通の文字列にして、
//  両方の Info.plist の NSUserActivityTypes に書いておく (書かないと候補に出ない)。
//
//  ── 窓ごとに一人 ──
//  TabManager が一人ずつ持つ。選んでいるタブが変わったら follow を呼んでもらい、
//  そのタブの中で行き先や題が変わったら、自分で追いかけて知らせ直す。
//  窓が何枚もあるときは、最後に becomeCurrent() した物が知らされる。
//  そこで ContentView が「窓が手前に来た」ときにも follow を呼び、手前の窓で上書きする。
//
//  ── 知らせない物 ──
//  ・プライベートウィンドウのページ (端末をまたいで足跡を残さない)
//  ・ロビー、http / https 以外の場所
//

import AppKit
import Combine
import WebKit

final class HandoffPublisher {
    /// Mezzanine と共通の、活動の種類
    static let activityType = "net.live-on.inugamine.browsing"

    private var activity: NSUserActivity?
    private var watch: AnyCancellable?

    /// 選んでいるタブが変わったとき・窓が手前に来たときに呼ぶ
    func follow(_ tab: Tab?, isPrivate: Bool) {
        watch = nil
        guard let tab, !isPrivate else {
            stop()
            return
        }
        // 行き先 (urlText は WebView の url から作られる) と題のどちらが変わっても知らせ直す。
        // @Published は値が入る直前に流れるので、題は流れてきた値を使う
        watch = tab.$urlText.removeDuplicates()
            .combineLatest(tab.$pageTitle.removeDuplicates())
            .sink { [weak self, weak tab] _, title in
                guard let self, let tab else { return }
                self.publish(tab, title: title)
            }
    }

    /// 窓を閉じたときなどに呼ぶ。知らせを取り下げる
    func stop() {
        watch = nil
        activity?.invalidate()
        activity = nil
    }

    private func publish(_ tab: Tab, title: String) {
        guard !tab.isHome,
              let url = tab.webView.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            activity?.invalidate()
            activity = nil
            return
        }
        let current = activity ?? NSUserActivity(activityType: Self.activityType)
        current.title = title
        current.webpageURL = url
        current.isEligibleForHandoff = true
        activity = current
        current.becomeCurrent()
    }
}
