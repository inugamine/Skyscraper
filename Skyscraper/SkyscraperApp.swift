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

// Tabs メニューのピン留めの一行。
//
// Commands の中身は View でも良いので、ここだけを
// @ObservedObject を持つ View に切り出す。
// こうすれば tabs が差し替わるたびに描き直され、
// 札の文言が実態とずれない
private struct PinTabCommand: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        Button(manager.selectedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
            if let tab = manager.selectedTab { manager.togglePin(tab) }
        }
        .disabled(manager.selectedTab == nil)
    }
}

@main
struct SkyscraperApp: App {
    // AppKit の代理人。他のアプリから投げられた URL を受けるためだけに居る。
    // SwiftUI の .onOpenURL を使わない理由は IncomingURL.swift の冒頭に書いた
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // ブックマークと更新確認は窓をまたいで共通。
    // タブの管理人だけが窓ごとになる（ContentView が自分で持つ）
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var updater = Updater()

    init() {
        // 拡張機能を読み込む。
        // 置き場所は ~/Library/Application Support/Skyscraper/Extensions/。
        //
        // WKWebExtension の生成が async なのでここで待てない。
        // 最初のタブより後になる可能性があるが、controller 自体は
        // 既に全 WKWebView に刺さっているので、後から拡張を足しても届く
        Task { await WebExtensionManager.shared.loadAll() }

        // 絵札（ファビコン）の間引き。
        // 古びた分を捨て、枚数を上限に収める。
        // 中身は別スレッドへ逃げているので、起動は待たされない
        FaviconStore.shared.pruneOnLaunch()
    }

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
            BrowserCommands(bookmarks: bookmarks)
        }

        // 設定画面（⌘, で開く。Sparkle のダイアログが案内する「設定」の実体）
        Settings {
            SettingsView(updater: updater, bookmarks: bookmarks)
        }
    }
}

// メニュー本体。
// @FocusedValue は View か Commands の中でしか使えないので、
// App から切り出して独立した Commands にしてある。
// manager が nil になるのは、どの窓にも focus が無い時（設定画面だけ開いている等）
struct BrowserCommands: Commands {
    // ブックマークは窓をまたいで一つなので、focus ではなく App から直に受け取る。
    // 見張る必要は無い（メニューからは入れるだけで、中身を読まない）
    let bookmarks: BookmarkStore

    @FocusedValue(\.tabManager) private var manager: TabManager?
    @FocusedValue(\.translator) private var translator: Translator?

    // ブックマークバーを出すか。
    // BrowserPane と同じ鍵を見ているだけで、中継ぎは要らない——
    // UserDefaults の変化は @AppStorage を持つ全員に届くので、
    // ここで倒せば全ての窓の帯が揃って引っ込む
    @AppStorage("bookmarkBarVisible") private var showsBookmarkBar = true

    var body: some Commands {
        // File メニュー：SwiftUI が用意する New Window（⌘N）の下にタブ操作を並べる。
        // 以前は replacing で New Window ごと潰していた
        CommandGroup(after: .newItem) {
            // 普通の窓（⌘N）の直下に置く。
            // 窓を開くのは View の仕事なので、管理人に合図を送らせる
            Button("New Private Window") { manager?.openPrivateWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(manager == nil)
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
        // 他所のブラウザからの引っ越し。
        // .importExport は File メニューの「書き出し」の定位置で、
        // macOS の他のアプリもここに置いている
        CommandGroup(after: .importExport) {
            Button("Import Bookmarks…") {
                BookmarkImport.chooseFile(into: bookmarks)
            }
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
            // チェック付きの項目になる（Safari の「お気に入りバーを隠す」と
            // 同じ場所）。窓が一つも無くても効くので disabled は付けない
            Toggle("Show Bookmarks Bar", isOn: $showsBookmarkBar)
                .keyboardShortcut("b", modifiers: .command)
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
            // 全ての窓のタブを串刺しで探す。
            // ⌘A（全選択）とは別物なので ⇧⌘A——Safari と同じ位置だ
            Button("Search Tabs…") { manager?.showTabSearch() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(manager == nil)
            Divider()
            // ピン留め。札の文言が今の状態で変わるので、
            // 管理人を見張る View（PinTabCommand）に包んである。
            // @FocusedValue は値を渡すだけで、中身の変化を見張らない——
            // ここで直に三項演算子を書くと、留めた後も
            // 「Pin Tab」のまま古びる
            if let manager {
                PinTabCommand(manager: manager)
            } else {
                Button("Pin Tab") {}.disabled(true)
            }
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
