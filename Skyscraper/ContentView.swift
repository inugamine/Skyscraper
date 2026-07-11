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
    static let ink       = Color(red: 0x0d/255, green: 0x0d/255, blue: 0x0d/255)
    static let panel     = Color(red: 0x14/255, green: 0x12/255, blue: 0x10/255)
    static let panel2    = Color(red: 0x1a/255, green: 0x17/255, blue: 0x12/255)
    static let field     = Color(red: 0x16/255, green: 0x13/255, blue: 0x10/255)
    static let gold      = Color(red: 0xc9/255, green: 0xa3/255, blue: 0x4e/255)
    static let cream     = Color(red: 0xe8/255, green: 0xd9/255, blue: 0xb0/255)
    static let dimGold   = Color(red: 0x8a/255, green: 0x7a/255, blue: 0x52/255)
    static let faintGold = Color(red: 0x5a/255, green: 0x4c/255, blue: 0x2a/255)
}

// MARK: - 自作シェイプ

struct Hexagon: Shape {
    var inset: CGFloat = 9
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let i = min(inset, w / 2)
        p.move(to: CGPoint(x: i, y: rect.minY))
        p.addLine(to: CGPoint(x: w - i, y: rect.minY))
        p.addLine(to: CGPoint(x: w, y: rect.midY))
        p.addLine(to: CGPoint(x: w - i, y: rect.maxY))
        p.addLine(to: CGPoint(x: i, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

struct Zigzag: Shape {
    var teeth: Int = 14
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step = rect.width / CGFloat(max(teeth, 1))
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var x = rect.minX
        var top = true
        while x < rect.maxX - 0.5 {
            x = min(x + step, rect.maxX)
            p.addLine(to: CGPoint(x: x, y: top ? rect.minY : rect.maxY))
            top.toggle()
        }
        return p
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - ブックマーク（保存対応）

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] {
        didSet { save() }
    }

    private let key = "skyscraper.bookmarks.v1"

    init() {
        // 保存済みがあれば読み込む。無ければ初期セット
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        } else {
            bookmarks = [
                Bookmark(title: "Apple",       url: "https://www.apple.com"),
                Bookmark(title: "GitHub",      url: "https://github.com"),
                Bookmark(title: "Hacker News", url: "https://news.ycombinator.com"),
                Bookmark(title: "Wikipedia",   url: "https://www.wikipedia.org"),
            ]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    // 星ボタン用：登録済みなら外す、無ければ足す
    func toggle(title: String, url: String) {
        guard !url.isEmpty else { return }
        if let idx = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(Bookmark(title: title.isEmpty ? url : title, url: url))
        }
    }

    func addBlank() {
        bookmarks.append(Bookmark(title: String(localized: "New bookmark"), url: "https://"))
    }

    func remove(_ bm: Bookmark) {
        bookmarks.removeAll { $0.id == bm.id }
    }

    func moveUp(_ i: Int) {
        guard i > 0, i < bookmarks.count else { return }
        bookmarks.swapAt(i, i - 1)
    }

    func moveDown(_ i: Int) {
        guard i >= 0, i < bookmarks.count - 1 else { return }
        bookmarks.swapAt(i, i + 1)
    }
}

// MARK: - WKWebView ラッパー

struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
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
    @Published var isHome: Bool = true
    @Published var addressBarFocusTrigger: Int = 0

    private var observers: [NSKeyValueObservation] = []

    init(url: String? = nil) {
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

        if let url {
            urlText = url
            load()
        }
    }

    func load() {
        guard let url = Tab.resolveURL(from: urlText) else { return }
        isHome = false
        webView.load(URLRequest(url: url))
    }

    // 入力が URL か検索語かを見分ける。URL ならそのまま、そうでなければ Google 検索にする
    static func resolveURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // すでに http/https が付いていれば URL として扱う
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return URL(string: text)
        }

        // 空白が無く、ドットを含む（または localhost）ならホスト名とみなす
        let looksLikeHost = !text.contains(" ")
            && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://" + text) {
            return url
        }

        // それ以外は Google 検索に流す
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload() }

    // アドレスバーにフォーカスを移す合図を送る
    func focusAddressBar() { addressBarFocusTrigger += 1 }

    // ズーム（ページの拡大率を 50%〜300% の範囲で変える）
    func zoomIn()    { setZoom(webView.pageZoom + 0.1) }
    func zoomOut()   { setZoom(webView.pageZoom - 0.1) }
    func zoomReset() { setZoom(1.0) }
    private func setZoom(_ value: CGFloat) {
        webView.pageZoom = min(max(value, 0.5), 3.0)
    }
}

// MARK: - タブ全体を束ねる管理役

@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?

    // 閉じたタブの復元用スタック（URL。空文字はロビー）
    private var recentlyClosed: [String] = []

    init() { addTab() }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID }
    }

    func addTab(url: String? = nil) {
        let tab = Tab(url: url)
        tabs.append(tab)
        selectedID = tab.id
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // 復元用に、閉じるタブの URL を控える（ロビーなら空文字）。控えは最大20件
        let restoreURL = tab.isHome ? "" : (tab.webView.url?.absoluteString ?? tab.urlText)
        recentlyClosed.append(restoreURL)
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        tabs.remove(at: idx)
        if selectedID == tab.id {
            selectedID = tabs[safe: idx]?.id ?? tabs.last?.id
        }
        if tabs.isEmpty { addTab() }
    }

    func select(_ tab: Tab) { selectedID = tab.id }

    func closeSelected() {
        if let tab = selectedTab { closeTab(tab) }
    }

    // 直近に閉じたタブを開き直す
    func reopenClosed() {
        guard let url = recentlyClosed.popLast() else { return }
        addTab(url: url.isEmpty ? nil : url)
    }

    // 番号でタブを選ぶ（0始まり）
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 段々ビルのイラスト

struct SkyscraperMark: View {
    var color: Color = Deco.gold
    var body: some View {
        VStack(spacing: 0) {
            Triangle().stroke(color, lineWidth: 1).frame(width: 3, height: 16)
            tier(18, 18)
            tier(34, 24)
            tier(52, 28)
            tier(74, 22)
        }
    }
    private func tier(_ w: CGFloat, _ h: CGFloat) -> some View {
        Rectangle().stroke(color, lineWidth: 1).frame(width: w, height: h)
    }
}

// MARK: - 新規タブページ（ロビー）

struct NewTabPage: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BookmarkStore

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            SkyscraperMark()
            VStack(spacing: 6) {
                Text("SKYSCRAPER")
                    .font(.system(size: 16, design: .serif))
                    .tracking(4)
                    .foregroundColor(Deco.cream)
                Text("ASCENDING SINCE MMXXVI")
                    .font(.system(size: 10, design: .serif))
                    .tracking(3)
                    .foregroundColor(Deco.faintGold)
            }

            HStack(spacing: 12) {
                ForEach(Array(store.bookmarks.prefix(5))) { bm in
                    Button {
                        tab.urlText = bm.url
                        tab.load()
                    } label: {
                        Text(bm.title)
                            .font(.system(size: 12, design: .serif))
                            .tracking(1)
                            .foregroundColor(Deco.gold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .overlay(Hexagon(inset: 7).stroke(Deco.faintGold, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deco.ink)
    }
}

// MARK: - 垂直タブバー

struct VerticalTabStrip: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.bottom, 10)

            Zigzag(teeth: 14)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
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

            Zigzag(teeth: 14)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 14)
                .padding(.top, 8)

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
    private let shape = Hexagon(inset: 9)

    var body: some View {
        HStack(spacing: 6) {
            (tab.pageTitle.isEmpty ? Text("New Tab") : Text(verbatim: tab.pageTitle))
                .font(.system(size: 12, design: .serif))
                .foregroundColor(isSelected ? Deco.cream : Deco.dimGold)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            if hovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(Deco.dimGold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(shape.fill(isSelected ? Deco.ink : (hovering ? Deco.panel2 : Color.clear)))
        .overlay(shape.stroke(isSelected ? Deco.gold : Deco.faintGold,
                              lineWidth: isSelected ? 1 : 0.5))
        .contentShape(shape)
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

// MARK: - ブックマークバー

struct BookmarkBar: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BookmarkStore
    @State private var showingManager = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "diamond")
                .font(.system(size: 8))
                .foregroundColor(Deco.faintGold)
                .padding(.trailing, 6)

            ForEach(store.bookmarks) { bm in
                Button {
                    tab.urlText = bm.url
                    tab.load()
                } label: {
                    Text(bm.title)
                        .font(.system(size: 11, design: .serif))
                        .foregroundColor(Deco.dimGold)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) { store.remove(bm) }
                }
            }

            Spacer()

            Button {
                showingManager = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.dimGold)
            }
            .buttonStyle(.plain)
            .help("Edit bookmarks")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Deco.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Deco.faintGold).frame(height: 1)
        }
        .sheet(isPresented: $showingManager) {
            BookmarkManager()
                .environmentObject(store)
        }
    }
}

// MARK: - ブックマーク管理シート

struct BookmarkManager: View {
    @EnvironmentObject var store: BookmarkStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("Bookmarks")
                    .font(.system(size: 15, design: .serif))
                    .tracking(2)
                    .foregroundColor(Deco.cream)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundColor(Deco.dimGold)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Zigzag(teeth: 20)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 16)

            // 一覧
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($store.bookmarks) { $bm in
                        let idx = store.bookmarks.firstIndex(where: { $0.id == bm.id }) ?? 0
                        HStack(spacing: 8) {
                            VStack(spacing: 2) {
                                Button { store.moveUp(idx) } label: {
                                    Image(systemName: "chevron.up").font(.system(size: 9))
                                        .foregroundColor(idx == 0 ? Deco.faintGold : Deco.gold)
                                }
                                .buttonStyle(.plain).disabled(idx == 0)
                                Button { store.moveDown(idx) } label: {
                                    Image(systemName: "chevron.down").font(.system(size: 9))
                                        .foregroundColor(idx == store.bookmarks.count - 1 ? Deco.faintGold : Deco.gold)
                                }
                                .buttonStyle(.plain).disabled(idx == store.bookmarks.count - 1)
                            }

                            TextField("Name", text: $bm.title)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .serif))
                                .foregroundColor(Deco.cream)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Deco.field)
                                .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 0.5))
                                .frame(width: 130)

                            TextField("URL", text: $bm.url)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .serif))
                                .foregroundColor(Deco.gold)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Deco.field)
                                .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 0.5))

                            Button { store.remove(bm) } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                                    .foregroundColor(Deco.dimGold)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }

            // フッター
            HStack {
                Button { store.addBlank() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("Add").font(.system(size: 12, design: .serif)).tracking(1)
                    }
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .overlay(Hexagon(inset: 7).stroke(Deco.faintGold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Deco.ink)
    }
}

// MARK: - 選択中タブの中身

struct BrowserPane: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BookmarkStore
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── アドレスバー ──
            HStack(spacing: 10) {
                NavButton(system: "chevron.left",  disabled: !tab.canGoBack)    { tab.goBack() }
                NavButton(system: "chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
                NavButton(system: "arrow.clockwise", disabled: false)           { tab.reload() }

                TextField("Search or enter address", text: $tab.urlText, onCommit: { tab.load() })
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Hexagon(inset: 6).fill(Deco.field))
                    .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))

                // 星ボタン：現在のページを登録／解除
                Button {
                    store.toggle(title: tab.pageTitle, url: tab.urlText)
                } label: {
                    Image(systemName: store.isBookmarked(tab.urlText) ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundColor(tab.isHome ? Deco.faintGold : Deco.gold)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(tab.isHome)

                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Deco.gold)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Deco.panel)

            // ── ブックマークバー ──
            BookmarkBar(tab: tab)

            // ── 中身：ロビー or Web ──
            if tab.isHome {
                NewTabPage(tab: tab)
            } else {
                WebView(webView: tab.webView)
            }
        }
        .navigationTitle(tab.pageTitle.isEmpty ? "Skyscraper" : tab.pageTitle)
        .onChange(of: tab.addressBarFocusTrigger) { _, _ in
            addressFocused = true
        }
    }
}

// MARK: - 全体

struct ContentView: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var bookmarks: BookmarkStore

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
        .environmentObject(bookmarks)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView(manager: TabManager(), bookmarks: BookmarkStore())
}
