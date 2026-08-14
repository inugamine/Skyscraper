//
//  WebExtensionBridge.swift
//  Skyscraper
//
//  拡張機能から見た「タブ」と「窓」を用意する。
//
//  ── なぜ要るのか ──
//  DNR（宣言的な通信遮断）は WebKit がエンジンで実行するので、
//  こちらが何もしなくても効く。だが拡張の中身はそれだけではない。
//  uBOL のコンテンツスクリプトは、ページを開くたびに
//  「このホストに当てる整形フィルタは何か」を runtime.sendMessage() で
//  バックグラウンドに訊きに行く。その時 WebKit は
//  「この問い合わせはどのタブから来たのか」を解決しようとして、
//  タブの名簿が無いと "Tab not found" で弾く。
//  結果、通信は止まるのに広告の空枠だけが残る。
//
//  そこで Tab を WKWebExtensionTab に、TabManager を
//  WKWebExtensionWindow に見立てて名簿を差し出す。
//
//  ── 実装の範囲 ──
//  プロトコルの要求は全て optional なので、綴りを間違えても
//  コンパイルは通ってしまう（黙って呼ばれなくなるだけ）。
//  当てずっぽうで広く実装せず、要る順に足して挙動で確かめる。
//

import AppKit
import WebKit

// MARK: - タブ

extension Tab: WKWebExtensionTab {
    // 一番大事な一本。これが無いと何も始まらない
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    // 自分がどの窓に属しているか。
    // Tab は持ち主への参照を持っていないので、名簿から引き直す。
    // 窓もタブも数十枚が上限なので、総当たりで足りる
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        TabManager.owner(of: id)?.manager
    }

    func title(for context: WKWebExtensionContext) -> String? {
        pageTitle.isEmpty ? nil : pageTitle
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        TabManager.owner(of: id)?.manager.selectedID == id
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        isMuted
    }

    // リーダーモードの有無。既に自前で持っているので素直に渡す
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        isReaderAvailable
    }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool {
        isReaderActive
    }

    // ── 拡張からの操作 ──
    // 今の uBOL はここをほとんど使わないが、popup を出す段で要る

    func activate(for context: WKWebExtensionContext,
                  completionHandler: @escaping ((any Error)?) -> Void) {
        TabManager.owner(of: id)?.manager.select(self)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext,
               completionHandler: @escaping ((any Error)?) -> Void) {
        TabManager.owner(of: id)?.manager.closeTab(self)
        completionHandler(nil)
    }

    func reload(for context: WKWebExtensionContext,
                fromOrigin: Bool,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin {
            reloadFromOrigin()
        } else {
            reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
        goForward()
        completionHandler(nil)
    }

    func loadURL(_ url: URL,
                 for context: WKWebExtensionContext,
                 completionHandler: @escaping ((any Error)?) -> Void) {
        urlText = url.absoluteString
        load()
        completionHandler(nil)
    }

    func setMuted(_ muted: Bool,
                  for context: WKWebExtensionContext,
                  completionHandler: @escaping ((any Error)?) -> Void) {
        if isMuted != muted { toggleMute() }
        completionHandler(nil)
    }
}

// MARK: - 窓

// Skyscraper では窓一枚につき TabManager が一人居るので、
// そのまま「窓」として差し出せる
extension TabManager: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        tabs
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        selectedTab
    }

    // 実体の NSWindow。タブの WebView が載っている窓を借りる。
    // TabManager 自身は窓を持っていない（持ち主は SwiftUI）
    private var hostWindow: NSWindow? {
        selectedTab?.webView.window ?? tabs.first?.webView.window
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext,
               completionHandler: @escaping ((any Error)?) -> Void) {
        hostWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}

// MARK: - 名簿の更新を管理役へ流す

extension WebExtensionManager {
    // tabs 配列の差分から、開いた／閉じたを拾って WebKit に知らせる。
    //
    // 挿入経路が addTab / addTabInBackground / addPopupTab / reopenClosed /
    // restoreSession / adopt と六つあるので、個別に差し込むと必ず漏れる。
    // TabManager.tabs の didSet 一箇所で差分を取る方が確実だ
    func tabsChanged(from oldTabs: [Tab], to newTabs: [Tab], in manager: TabManager) {
        guard !contexts.isEmpty else { return }

        let oldIDs = Set(oldTabs.map(\.id))
        let newIDs = Set(newTabs.map(\.id))

        for tab in newTabs where !oldIDs.contains(tab.id) {
            controller.didOpenTab(tab)
        }
        for tab in oldTabs where !newIDs.contains(tab.id) {
            controller.didCloseTab(tab, windowIsClosing: manager.isClosed)
        }
    }

    func tabDidActivate(_ tab: Tab?, previous: Tab?) {
        guard !contexts.isEmpty, let tab else { return }
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func windowDidOpen(_ manager: TabManager) {
        guard !contexts.isEmpty else { return }
        controller.didOpenWindow(manager)
        // 窓を登録した後で、中に居るタブを改めて名乗らせる。
        //
        // 復元経路では init の段階で tabs に積まれるので、
        // didSet 経由の didOpenTab はこの didOpenWindow より先に飛んでいる。
        // WebKit から見れば「所属不明のタブが先に来た」形になり、
        // tabsForWebExtensionContext と activeTab の不整合を指摘される。
        // 同じタブを二度 didOpenTab しても WebKit 側で同一性で拾われる
        for tab in manager.tabs {
            controller.didOpenTab(tab)
        }
        if let selected = manager.selectedTab {
            controller.didActivateTab(selected, previousActiveTab: nil)
        }
        controller.didFocusWindow(manager)
    }

    func windowDidClose(_ manager: TabManager) {
        guard !contexts.isEmpty else { return }
        controller.didCloseWindow(manager)
    }
}
