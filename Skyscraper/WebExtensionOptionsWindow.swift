//
//  WebExtensionOptionsWindow.swift
//  Skyscraper
//
//  拡張機能の設定ページ（options page）を出すための専用窓。
//
//  ── なぜタブで開かないのか ──
//  設定ページの URL は webkit-extension:// スキームで、
//  WebKit は「その拡張専用の WKWebViewConfiguration で作られた WebView」
//  以外からの読み込みを問答無用で取り消す（context.webViewConfiguration の
//  説明にそう書かれている）。
//
//  Tab.makeWebView は通常経路と window.open() 経路の二本立てで、
//  OAuth の window.opener も全画面の引っこ抜きもそこを通っている。
//  年に数回開くかどうかの設定画面のために三本目を通すのは割に合わない。
//  素直に別の窓を立てる。
//
//  ── 窓の寿命 ──
//  NSWindow は誰かが持っていないと閉じた途端に解放される。
//  拡張ごとに一枚だけ持ち、二度目からは同じ窓を前に出す。
//

import AppKit
import WebKit

@MainActor
final class WebExtensionOptionsWindowController: NSObject {
    static let shared = WebExtensionOptionsWindowController()

    // 拡張の uniqueIdentifier ごとに一枚
    private var windows: [String: NSWindow] = [:]

    private override init() {}

    // 設定ページを開く。既に開いていればそれを前に出す
    func show(for context: WKWebExtensionContext) -> Bool {
        let key = context.uniqueIdentifier

        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        guard let url = context.optionsPageURL else {
            print("WebExtension options: no options page for \(key)")
            return false
        }
        // この設定を使わずに作った WebView からは、
        // webkit-extension:// への遷移が取り消される
        guard let configuration = context.webViewConfiguration else {
            print("WebExtension options: no webViewConfiguration for \(key)")
            return false
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 680),
                                configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        // 設定ページの中身は拡張が描く。開発時に覗けるようにしておく
        webView.isInspectable = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = context.webExtension.displayName ?? key
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 窓の見分けに使う（閉じた時に名簿から外すため）
        window.identifier = NSUserInterfaceItemIdentifier(key)

        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: url))
        return true
    }
}

// MARK: - 窓が閉じられたら名簿から外す

extension WebExtensionOptionsWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow,
                  let key = window.identifier?.rawValue else { return }
            // 中身の WebView も一緒に手放す。
            // 抱えたままだと、閉じた設定ページが裏で生き続ける
            (window.contentView as? WKWebView)?.stopLoading()
            window.contentView = nil
            windows[key] = nil
        }
    }
}
