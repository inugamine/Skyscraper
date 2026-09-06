//
//  IncomingURL.swift
//  Skyscraper
//
//  他のアプリから渡された URL を受け取る係。ExternalScheme.swift の裏返しだ。
//  あちらは「WKWebView が開けないものを外へ出す」、こちらは「外から来たものを中で開く」。
//
//  既定のブラウザというのは、要するに「他のアプリから URL を投げつけられる係」だ。
//  Mail のリンク、Slack のリンク、Terminal の open コマンド——
//  全部この口から入ってくる。Info.plist で http / https を扱えると名乗った以上、
//  受け取って開くところまでが責任の範囲になる。
//
//  ── なぜ SwiftUI の .onOpenURL を使わないのか ──
//  あれは WindowGroup の中に書くと、窓が三枚開いている時にどれが受けるかが
//  SwiftUI 任せになる。同じ URL が複数枚に開く事故が起きやすい。
//  AppKit の application(_:open:) はアプリに一度だけ届くのが保証されているので、
//  受け口はそちらに寄せて、行き先はこちらで決める。
//
//  ── 窓が一枚も無い時 ──
//  アプリを終了した状態でリンクを押されると、URL が先に届いて窓がまだ無い。
//  openWindow は View の環境にしか居ないのでここからは呼べない。
//  そこでセッション復元（pendingRestores）と同じ手を使う——
//  預かり所に積んでおき、窓が生まれた時に ContentView から引き取らせる。
//

import AppKit

@MainActor
enum IncomingURL {
    // 窓の誕生を待っている宛先。窓さえあれば経由しない
    private static var pending: [URL] = []

    // 窓を開かせるための連絡先（ContentView が入れる）。
    // openWindow は環境の値なので、こちらから掴みには行けない
    private static var windowOpener: (() -> Void)?

    static func registerWindowOpener(_ opener: @escaping () -> Void) {
        windowOpener = opener
    }

    // MARK: - 受け口

    static func receive(_ urls: [URL]) {
        for url in urls where isWeb(url) {
            deliver(url)
        }
    }

    // http / https だけを引き受ける。
    //
    // file:// は弾く。Info.plist で書類の型を名乗っていないので
    // そもそも渡されないし、仮に渡されても WKWebView は
    // load(URLRequest:) では地元のファイルを開けない
    //（loadFileURL(_:allowingReadAccessTo:) が要る）。
    // 開けないものを受け取ったふりをするのが一番たちが悪い
    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func deliver(_ url: URL) {
        guard let manager = TabManager.externalURLTarget else {
            // 行き先が無い。窓を生ませて、そちらに引き取ってもらう
            pending.append(url)
            windowOpener?()
            return
        }
        manager.addTab(url: url.absoluteString)
        // 投げた側のアプリの後ろに隠れたままでは、開いた意味がない
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 預かり分の引き取り

    // 窓が開いた時に ContentView から呼ばれる。
    // 積まれている分を全て新しいタブで開く（Safari と同じ流儀だ——
    // 外から来たリンクで今見ているページを潰さない）
    static func drain(into manager: TabManager) {
        guard !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        for url in urls {
            manager.addTab(url: url.absoluteString)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - AppKit の受け口

// SwiftUI の App に差す代理人。今のところ仕事はこれ一つだ。
// 増やす時は、ここが何でも屋にならないよう気を付けること
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        IncomingURL.receive(urls)
    }
}
