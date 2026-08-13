//
//  SkyscraperApp.swift
//  Skyscraper
//
//  Created by inugaminé on 2026/07/11.
//

import SwiftUI

// 手前にある窓の管理人をメニューへ渡すための鍵。
//
// 管理人が窓ごとになったので、メニューは「今どの窓が手前か」を
// 知らないと誰に命令していいか分からない。
// SwiftUI の答えがこれで、各窓が自分の管理人を差し出し、
// メニュー側は focus のある窓のものを受け取る
struct FocusedTabManagerKey: FocusedValueKey {
    typealias Value = TabManager
}

// 翻訳役も同じ理屈で窓ごとに居る。
// 盤は手前の窓の右端に出すので、メニューはこちらも受け取る
struct FocusedTranslatorKey: FocusedValueKey {
    typealias Value = Translator
}

extension FocusedValues {
    var tabManager: TabManager? {
        get { self[FocusedTabManagerKey.self] }
        set { self[FocusedTabManagerKey.self] = newValue }
    }

    var translator: Translator? {
        get { self[FocusedTranslatorKey.self] }
        set { self[FocusedTranslatorKey.self] = newValue }
    }
}

@main
struct SkyscraperApp: App {
    // ブックマークと更新確認は窓をまたいで共通。
    // タブの管理人だけが窓ごとになる（ContentView が自分で持つ）
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup(id: "browser") {
            ContentView(bookmarks: bookmarks)
        }
        .commands {
            // アプリメニュー：「Skyscraper について」の下にアップデート確認を置く
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            BrowserCommands()
        }

        // 設定画面（⌘, で開く。Sparkle のダイアログが案内する「設定」の実体）
        Settings {
            SettingsView(updater: updater)
        }
    }
}

// メニュー本体。
// @FocusedValue は View か Commands の中でしか使えないので、
// App から切り出して独立した Commands にしてある。
// manager が nil になるのは、どの窓にも focus が無い時（設定画面だけ開いている等）
struct BrowserCommands: Commands {
    @FocusedValue(\.tabManager) private var manager: TabManager?
    @FocusedValue(\.translator) private var translator: Translator?

    var body: some Commands {
        // File メニュー：SwiftUI が用意する New Window（⌘N）の下にタブ操作を並べる。
        // 以前は replacing で New Window ごと潰していた
        CommandGroup(after: .newItem) {
            Button("New Tab") { manager?.addTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(manager == nil)
            Button("Close Tab") { manager?.closeSelected() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(manager == nil)
            Button("Reopen Closed Tab") { manager?.reopenClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(manager == nil)
            Button("Open Location") { manager?.selectedTab?.focusAddressBar() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(manager == nil)
        }
        // File メニューの「保存」「印刷」は macOS が置き場所を決めている。
        // 自前の CommandMenu を足すのではなく、その定位置に相乗りする。
        // replacing でも、SwiftUI が既定で何も置いていない場合は
        // 単にその位置へ差し込まれる
        CommandGroup(replacing: .saveItem) {
            Button("Save Page As…") {
                if let tab = manager?.selectedTab { PageExporter.savePage(tab) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager == nil)

            Button("Export as PDF…") {
                if let tab = manager?.selectedTab { PageExporter.exportPDF(tab) }
            }
            .disabled(manager == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                if let tab = manager?.selectedTab { PageExporter.print(tab) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(manager == nil)
        }
        // Edit メニュー：ページ内検索
        CommandGroup(after: .textEditing) {
            Button("Find…") { manager?.selectedTab?.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(manager == nil)
            Button("Find Next") { manager?.selectedTab?.findAgain(backwards: false) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(manager == nil)
            Button("Find Previous") { manager?.selectedTab?.findAgain(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(manager == nil)
            Divider()
            // 選択した文字列を右端の盤で訳す。
            // ⌘⇧T は Reopen Closed Tab で埋まっているので ⌥⌘T
            Button("Translate Selection…") {
                if let webView = manager?.selectedTab?.webView {
                    translator?.translateSelection(in: webView)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(manager == nil || translator == nil)
        }
        // 表示メニュー：ズーム。
        // CommandMenu("View") だと macOS が既に持っている「表示」の隣に
        // 同名のメニューがもう一つ生えるので、既存の方に相乗りする
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { manager?.selectedTab?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(manager == nil)
            Button("Zoom Out") { manager?.selectedTab?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(manager == nil)
            Button("Actual Size") { manager?.selectedTab?.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(manager == nil)
        }
        // History メニュー：戻る・進む・再読み込み
        CommandMenu("History") {
            Button("Back") { manager?.selectedTab?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(manager == nil)
            Button("Forward") { manager?.selectedTab?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(manager == nil)
            Divider()
            Button("Reload") { manager?.selectedTab?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(manager == nil)
            Button("Reload Without Cache") { manager?.selectedTab?.reloadFromOrigin() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(manager == nil)
        }
        // Tabs メニュー：タブ送りと ⌘1〜⌘9
        CommandMenu("Tabs") {
            Button("Show Next Tab") { manager?.selectAdjacentTab(offset: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(manager == nil)
            Button("Show Previous Tab") { manager?.selectAdjacentTab(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(manager == nil)
            Divider()
            Button("Move Tab to New Window") { manager?.moveSelectedTabToNewWindow() }
                .disabled(manager == nil)
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { manager?.selectTab(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(manager == nil)
            }
        }
    }
}
