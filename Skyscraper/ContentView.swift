//
//  ContentView.swift
//  Skyscraper
//
//  Created by inugaminé on 2026/07/11.
//

import SwiftUI
import WebKit
import Combine

// MARK: - アール・デコ配色

enum Deco {
    static let ink       = Color(red: 0x0d/255, green: 0x0d/255, blue: 0x0d/255) // 背景の黒
    static let panel     = Color(red: 0x14/255, green: 0x12/255, blue: 0x10/255) // やや温かい黒
    static let panel2    = Color(red: 0x1a/255, green: 0x17/255, blue: 0x12/255) // ホバー時
    static let field     = Color(red: 0x16/255, green: 0x13/255, blue: 0x10/255) // 入力欄
    static let gold      = Color(red: 0xc9/255, green: 0xa3/255, blue: 0x4e/255) // 主役の金
    static let cream     = Color(red: 0xe8/255, green: 0xd9/255, blue: 0xb0/255) // 明るい文字
    static let dimGold   = Color(red: 0x8a/255, green: 0x7a/255, blue: 0x52/255) // 控えめな金
    static let faintGold = Color(red: 0x5a/255, green: 0x4c/255, blue: 0x2a/255) // 罫線・非活性
}

// MARK: - WKWebView ラッパー

struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - タブ一枚ぶんの状態

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let webView = WKWebView()

    @Published var urlText: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var pageTitle: String = ""

    private var observers: [NSKeyValueObservation] = []

    init(url: String = "https://www.apple.com") {
        urlText = url

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in if let u = wv.url { self?.urlText = u.absoluteString } }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoBack = wv.canGoBack }
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoForward = wv.canGoForward }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.isLoading = wv.isLoading }
        })
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.pageTitle = wv.title ?? "" }
        })

        load()
    }

    func load() {
        var text = urlText.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload() }
}

// MARK: - タブ全体を束ねる管理役

@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?

    init() { addTab() }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID }
    }

    func addTab(url: String = "https://www.apple.com") {
        let tab = Tab(url: url)
        tabs.append(tab)
        selectedID = tab.id
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if selectedID == tab.id {
            selectedID = tabs[safe: idx]?.id ?? tabs.last?.id
        }
        if tabs.isEmpty { addTab() }
    }

    func select(_ tab: Tab) { selectedID = tab.id }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 垂直タブバー（アール・デコ）

struct VerticalTabStrip: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── ロゴタイプ ──
            HStack(spacing: 8) {
                Image(systemName: "diamond")
                    .font(.system(size: 13))
                    .foregroundColor(Deco.gold)
                Text("SKYSCRAPER")
                    .font(.system(size: 14, design: .serif))
                    .tracking(3)
                    .foregroundColor(Deco.cream)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Deco.gold)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // ── タブ一覧 ──
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.tabs) { tab in
                        DecoTabRow(
                            tab: tab,
                            isSelected: tab.id == manager.selectedID,
                            onSelect: { manager.select(tab) },
                            onClose:  { manager.closeTab(tab) }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            // ── 新規タブ ──
            Button(action: { manager.addTab() }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                    Text("New Tab")
                        .font(.system(size: 12, design: .serif))
                        .tracking(2)
                }
                .foregroundColor(Deco.dimGold)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200)
        .background(Deco.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Deco.gold).frame(width: 2)
        }
    }
}

struct DecoTabRow: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // 選択中は金の縦バー
            Rectangle()
                .fill(isSelected ? Deco.gold : Color.clear)
                .frame(width: 3)

            Text(tab.pageTitle.isEmpty ? "新規タブ" : tab.pageTitle)
                .font(.system(size: 12, design: .serif))
                .foregroundColor(isSelected ? Deco.cream : Deco.dimGold)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if hovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(Deco.dimGold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9)
        .padding(.trailing, 10)
        .background(isSelected ? Deco.ink : (hovering ? Deco.panel2 : Color.clear))
        .overlay(
            Rectangle()
                .stroke(isSelected ? Deco.gold : Deco.faintGold,
                        lineWidth: isSelected ? 1 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - ナビゲーションボタン

struct NavButton: View {
    let system: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundColor(disabled ? Deco.faintGold : Deco.gold)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - 選択中タブの中身（アドレスバー＋Web表示）

struct BrowserPane: View {
    @ObservedObject var tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            // ── アドレスバー ──
            HStack(spacing: 10) {
                NavButton(system: "chevron.left",  disabled: !tab.canGoBack)    { tab.goBack() }
                NavButton(system: "chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
                NavButton(system: "arrow.clockwise", disabled: false)           { tab.reload() }

                TextField("URL を入力", text: $tab.urlText, onCommit: { tab.load() })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Deco.field)
                    .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1))

                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Deco.gold)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Deco.panel)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Deco.faintGold).frame(height: 1)
            }

            // ── Web 表示エリア ──
            WebView(webView: tab.webView)
        }
        .navigationTitle(tab.pageTitle.isEmpty ? "Skyscraper" : tab.pageTitle)
    }
}

// MARK: - 全体

struct ContentView: View {
    @StateObject private var manager = TabManager()

    var body: some View {
        HStack(spacing: 0) {
            VerticalTabStrip(manager: manager)

            if let tab = manager.selectedTab {
                BrowserPane(tab: tab)
                    .id(tab.id)
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Deco.ink)
    }
}

#Preview {
    ContentView()
}
