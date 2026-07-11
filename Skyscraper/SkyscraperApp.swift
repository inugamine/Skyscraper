//
//  SkyscraperApp.swift
//  Skyscraper
//
//  Created by inugaminé on 2026/07/11.
//

import SwiftUI

@main
struct SkyscraperApp: App {
    // 管理人はアプリの最上位に置き、画面からもメニューからも使えるようにする
    @StateObject private var manager = TabManager()
    @StateObject private var bookmarks = BookmarkStore()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager, bookmarks: bookmarks)
        }
        .commands {
            // File メニュー：タブの新規・クローズ・復元・アドレスバー
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { manager.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { manager.closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reopen Closed Tab") { manager.reopenClosed() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Open Location") { manager.selectedTab?.focusAddressBar() }
                    .keyboardShortcut("l", modifiers: .command)
            }
            // View メニュー：ズーム
            CommandMenu("View") {
                Button("Zoom In") { manager.selectedTab?.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { manager.selectedTab?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { manager.selectedTab?.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            // History メニュー：戻る・進む・再読み込み
            CommandMenu("History") {
                Button("Back") { manager.selectedTab?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { manager.selectedTab?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Reload") { manager.selectedTab?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Tabs メニュー：⌘1〜⌘9 でタブ1〜9
            CommandMenu("Tabs") {
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { manager.selectTab(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
    }
}
