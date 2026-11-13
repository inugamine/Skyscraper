//
//  SplitView.swift
//  Skyscraper
//
//  スプリットビュー。タブ二枚を「組」にして、一つの窓に並べて見せる。
//
//  ── 形は Chrome・Edge と同じ ──
//  アドレスバーは一本のまま、触っている側 (＝選択中のタブ) に付いていく。
//  組は帯の上でも二枚のタブのままで、どちらかを選べば二枚とも出る。
//  組の外のタブを選べば一枚表示に戻るが、組は解けない——選び直せばまた並ぶ。
//  片方を閉じる・他の窓へ移す・千切ると、組は解ける。
//
//  ── 入口 ──
//  帯の右クリック「Split View ▸ Left / Right / Top / Bottom」
//  (そのタブを、今見ているタブのどちら側に並べるか)。
//  もう一つは、タブを引っ張ってページの端 (外側 1/4) へ落とす。
//  ページの真ん中で放した時は受け取らないので、今まで通り千切れる。
//
//  ── WebView の置き方 ──
//  全タブの WebView を常に載せておく作りは変えていない (BrowserPane の頃のまま)。
//  見せる二枚だけ枠を半分にし、残りは今まで通り全面に敷いて伏せておく。
//  器 (WebViewContainer) を作り直さないよう、表でも裏でも同じ修飾子を通す
//

import SwiftUI
import AppKit
import WebKit
import Combine

// MARK: - 組

// 並べる向き
enum SplitAxis {
    case sideBySide   // 左右
    case stacked      // 上下
}

// 今見ているタブのどちら側に置くか
enum SplitEdge {
    case left, right, top, bottom
}

// タブ二枚の組。first が左 (上)、second が右 (下)
struct TabSplit: Equatable {
    var first: UUID
    var second: UUID
    var axis: SplitAxis
    // first の取り分 (0〜1)。境目を引っ張ると変わる
    var ratio: CGFloat = 0.5

    func contains(_ id: UUID) -> Bool { first == id || second == id }
}

// MARK: - 管理人の側

extension TabManager {
    // そのタブが入っている組。相手がもう居ない組は無いものとして扱う
    func split(containing id: UUID?) -> TabSplit? {
        guard let id,
              let split = splits.first(where: { $0.contains(id) }),
              tabs.contains(where: { $0.id == split.first }),
              tabs.contains(where: { $0.id == split.second }) else { return nil }
        return split
    }

    // 今、画面に並んでいる組 (選択中のタブが入っている組)
    var activeSplit: TabSplit? { split(containing: selectedID) }

    // 選択中のタブと並んで見えている相手
    var visiblePartner: Tab? {
        guard let split = activeSplit, let selectedID else { return nil }
        let other = split.first == selectedID ? split.second : split.first
        return tabs.first { $0.id == other }
    }

    // 画面に出ているか (選択中か、その相方)。畳む相手を選ぶ時に見る
    func isOnScreen(_ tab: Tab) -> Bool {
        tab.id == selectedID || activeSplit?.contains(tab.id) == true
    }

    // tab を other の edge 側に並べる。
    // どちらかが既に別の組に居たら、そちらは解いてから組み直す
    func makeSplit(_ tab: Tab, with other: Tab, on edge: SplitEdge) {
        guard tab.id != other.id,
              tabs.contains(where: { $0.id == tab.id }),
              tabs.contains(where: { $0.id == other.id }) else { return }
        dissolveSplit(containing: tab.id)
        dissolveSplit(containing: other.id)

        let tabFirst = edge == .left || edge == .top
        let axis: SplitAxis = (edge == .left || edge == .right) ? .sideBySide : .stacked

        // 帯の上でも隣に寄せる (組だと一目で分かるように)。
        // ピン留めの欄をまたぐ時は動かさない——留めの並びを崩してしまう
        if tab.isPinned == other.isPinned,
           let from = tabs.firstIndex(where: { $0.id == tab.id }) {
            var reordered = tabs
            let moved = reordered.remove(at: from)
            if let anchor = reordered.firstIndex(where: { $0.id == other.id }) {
                reordered.insert(moved, at: tabFirst ? anchor : anchor + 1)
                tabs = reordered
            }
        }

        splits.append(TabSplit(first: tabFirst ? tab.id : other.id,
                               second: tabFirst ? other.id : tab.id,
                               axis: axis))
        // 足した側を触っている側にする (Chrome と同じ)
        select(tab)
    }

    // 右クリックの「Split View」。今見ているタブと並べる
    func makeSplitWithSelected(_ tab: Tab, on edge: SplitEdge) {
        guard let current = selectedTab else { return }
        makeSplit(tab, with: current, on: edge)
    }

    // そのタブが入っている組を解く。タブは二枚とも残る
    func dissolveSplit(containing id: UUID) {
        guard splits.contains(where: { $0.contains(id) }) else { return }
        splits.removeAll { $0.contains(id) }
    }

    // 今並んでいる組を解く (メニューから)
    func exitActiveSplit() {
        guard let selectedID else { return }
        dissolveSplit(containing: selectedID)
    }

    // 境目を引っ張った。端まで寄せ切らせない
    func setSplitRatio(_ ratio: CGFloat, for split: TabSplit) {
        guard let index = splits.firstIndex(where: { $0.first == split.first && $0.second == split.second })
        else { return }
        splits[index].ratio = min(max(ratio, 0.2), 0.8)
    }

    // ── ページの端へのドロップ ──

    // 引っ張られてきたタブを、この窓で組にできるか
    func canAcceptSplitDrop(draggedID idString: String) -> Bool {
        guard let id = UUID(uuidString: idString),
              let (source, tab) = Self.owner(of: id),
              source.isPrivate == isPrivate,
              let current = selectedTab else { return false }
        // 今見ているタブ自身は、並べる相手が居ない
        return tab.id != current.id
    }

    @discardableResult
    func acceptSplitDrop(draggedID idString: String, on edge: SplitEdge) -> Bool {
        guard canAcceptSplitDrop(draggedID: idString),
              let id = UUID(uuidString: idString),
              let (source, tab) = Self.owner(of: id),
              // 相手は先に控える。他の窓から引き取ると、選択が引き取ったタブへ移る
              let current = selectedTab else { return false }
        if source !== self {
            source.moveTab(tab, to: self)
        }
        makeSplit(tab, with: current, on: edge)
        return true
    }

    // ── 触った側を選ぶ ──

    // ページの上でマウスが押された (SkyscraperWebView から)。
    // 並んでいる相方の方なら、そちらを選択中にする。アドレスバーが付いてくる
    static func focusPane(of webView: WKWebView) {
        for manager in openWindows {
            guard let partner = manager.visiblePartner,
                  partner.webView === webView else { continue }
            manager.select(partner)
            return
        }
    }
}

// MARK: - 割り付け

// 中身の領域を、組の二枚と境目に割る
private struct SplitLayout {
    // 境目の幅
    static let gap: CGFloat = 7
    // 枠の太さ。WebView はこの分だけ内側に置く
    // (AppKit のビューの上に SwiftUI の線を重ねない)
    static let border: CGFloat = 2

    let size: CGSize
    let split: TabSplit?

    private var full: CGRect { CGRect(origin: .zero, size: size) }

    // first / second の外枠と、境目
    private var parts: (first: CGRect, second: CGRect, divider: CGRect)? {
        guard let split else { return nil }
        switch split.axis {
        case .sideBySide:
            let w = ((size.width - Self.gap) * split.ratio).rounded()
            return (CGRect(x: 0, y: 0, width: w, height: size.height),
                    CGRect(x: w + Self.gap, y: 0,
                           width: max(0, size.width - w - Self.gap), height: size.height),
                    CGRect(x: w, y: 0, width: Self.gap, height: size.height))
        case .stacked:
            let h = ((size.height - Self.gap) * split.ratio).rounded()
            return (CGRect(x: 0, y: 0, width: size.width, height: h),
                    CGRect(x: 0, y: h + Self.gap,
                           width: size.width, height: max(0, size.height - h - Self.gap)),
                    CGRect(x: 0, y: h, width: size.width, height: Self.gap))
        }
    }

    var divider: CGRect? { parts?.divider }

    // そのタブの外枠。組に居なければ nil
    func frame(for id: UUID) -> CGRect? {
        guard let split, let parts else { return nil }
        if split.first == id { return parts.first }
        if split.second == id { return parts.second }
        return nil
    }

    // そのタブの中身を置く場所。組の外のタブは全面
    func content(for id: UUID) -> CGRect {
        guard let frame = frame(for: id) else { return full }
        return frame.insetBy(dx: Self.border, dy: Self.border)
    }
}

// MARK: - 中身の領域

// アドレスバーの下、ページが出る領域の全部。
// 以前は BrowserPane の中に ZStack で直に書いてあった
struct PaneArea: View {
    // 選択中のタブ (触っている側)
    @ObservedObject var tab: Tab
    @ObservedObject var manager: TabManager
    // タブを引っ張っている最中か。最中だけ、端へのドロップの受け皿を被せる
    @ObservedObject private var tearOff = TabTearOff.shared

    var body: some View {
        GeometryReader { geo in
            // 疑似大画面の間は一枚に戻す (動画に全面を明け渡す)
            let split = tab.isVideoFullscreen ? nil : manager.activeSplit
            let layout = SplitLayout(size: geo.size, split: split)

            ZStack(alignment: .topLeading) {
                // 全タブの WebView を常に画面に置き、見せる分だけを表に出す。
                // NSViewRepresentable は一度作った NSView を使い回すので、
                // 単一の WebView 枠だとタブを切り替えても最初の WebView が表示され続ける。
                // また、常時マウントにより裏タブの読み込み・タイトル更新も進む
                ForEach(manager.tabs) { t in
                    let onScreen = t.id == tab.id || split?.contains(t.id) == true
                    TabWebSlot(tab: t, onScreen: onScreen, rect: layout.content(for: t.id))
                }

                // ロビー・顛末書・小窓の留守番札。見えているタブの分だけ
                ForEach(manager.tabs) { t in
                    if t.id == tab.id || split?.contains(t.id) == true {
                        let rect = layout.content(for: t.id)
                        PaneContent(tab: t,
                                    isActive: t.id == tab.id,
                                    onActivate: { manager.select(t) })
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }

                if let split, let divider = layout.divider {
                    // 枠。触っている側だけ金にする
                    ForEach([split.first, split.second], id: \.self) { id in
                        if let frame = layout.frame(for: id) {
                            Rectangle()
                                .strokeBorder(id == tab.id ? Deco.gold : Deco.faintGold,
                                              lineWidth: SplitLayout.border)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    SplitDivider(axis: split.axis) { location in
                        let ratio = split.axis == .sideBySide
                            ? (location.x - SplitLayout.gap / 2) / max(1, geo.size.width - SplitLayout.gap)
                            : (location.y - SplitLayout.gap / 2) / max(1, geo.size.height - SplitLayout.gap)
                        manager.setSplitRatio(ratio, for: split)
                    }
                    .frame(width: divider.width, height: divider.height)
                    .position(x: divider.midX, y: divider.midY)
                }

                // タブを引っ張っている間だけ、ページの上に受け皿を被せる。
                // 被せないと、落とした先は WebView になる (文字として受け取られる)
                if tearOff.isDragging {
                    SplitDropCatcher(manager: manager)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: SplitDivider.space)
        }
    }
}

// タブ一枚ぶんの WebView。
// タブを見張っているので、相方がロビーへ戻った・読み込みに失敗した、も拾える
// (BrowserPane は選択中の一枚しか見張っていない)
private struct TabWebSlot: View {
    @ObservedObject var tab: Tab
    let onScreen: Bool
    let rect: CGRect

    var body: some View {
        // 顛末書やロビーを出している間は WebView を伏せる。
        // 上に重ねて隠すのではなく引っ込めるのは、AppKit のビューと
        // SwiftUI の重なり順を当てにしないため
        let showsWeb = onScreen && !tab.isHome && tab.loadError == nil
        // 小窓に出ているタブは、ここで WebView を作らない。
        // 作ると mount が小窓から WebView を引き抜く (FloatingWindow.swift)
        if tab.isFloating {
            Color.clear
        } else {
            WebView(webView: tab.webView, isInteractive: showsWeb)
                .opacity(showsWeb ? 1 : 0)
                .allowsHitTesting(showsWeb)
                // 器を作り直したら、こちらの器も組み直させる。
                // updateNSView は WKWebView の親子関係に一切触らないので、
                // .id を変えて makeNSView からやり直させる
                .id(tab.webViewGeneration)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

// WebView の代わりに出すもの (ロビー・顛末書・小窓の留守番札)。
// どれでもなければ何も出さない (下の WebView が見える)
private struct PaneContent: View {
    @ObservedObject var tab: Tab
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        Group {
            if tab.isFloating {
                FloatingPlaceholder {
                    FloatingPlayer.shared.returnToTab()
                }
            } else if let error = tab.loadError {
                ErrorPage(
                    error: error,
                    onRetry: { tab.retryFailedLoad() },
                    // 証明書を控えている時だけ札が出る。
                    // 押した先で中身を見せ、押し切られた時に限って通す
                    onProceed: tab.canProceedPastCertificateError
                        ? { Task { await tab.proceedPastCertificateError() } }
                        : nil
                )
            } else if tab.isHome {
                NewTabPage(tab: tab)
            }
        }
        // 触っていない側を押したら、そちらを選ぶ。押した先の釦もそのまま効く
        .simultaneousGesture(TapGesture().onEnded {
            if !isActive { onActivate() }
        })
    }
}

// MARK: - 境目

// 二枚の間の境目。引っ張ると比率が変わる
private struct SplitDivider: View {
    static let space = "skyscraper.splitArea"

    let axis: SplitAxis
    // 引っ張っている場所 (中身の領域の座標)
    let onDrag: (CGPoint) -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Deco.panel
            // 細い金の線と、真ん中の菱形
            Rectangle()
                .fill(hovering ? Deco.gold : Deco.faintGold)
                .frame(width: axis == .sideBySide ? 1 : nil,
                       height: axis == .stacked ? 1 : nil)
            Image(systemName: "diamond.fill")
                .font(.system(size: 5))
                .foregroundColor(hovering ? Deco.gold : Deco.dimGold)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                (axis == .sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { onDrag($0.location) }
        )
    }
}

// MARK: - 端へのドロップの受け皿

// タブを引っ張っている間だけページの上に被さる、AppKit の受け皿。
// 外側 1/4 の帯に入ると、並ぶ側の半分を金で染めて知らせる。
// 真ん中では受け取らない——そこで放せば、今まで通り千切れる
struct SplitDropCatcher: NSViewRepresentable {
    let manager: TabManager

    func makeNSView(context: Context) -> SplitDropCatcherView {
        let view = SplitDropCatcherView()
        view.manager = manager
        return view
    }

    func updateNSView(_ view: SplitDropCatcherView, context: Context) {
        view.manager = manager
    }
}

final class SplitDropCatcherView: NSView {
    weak var manager: TabManager?

    // 端と見なす帯の幅 (領域に対する割合)
    private static let band: CGFloat = 0.25

    private let highlight = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlight.isHidden = true
        layer?.addSublayer(highlight)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 左上を原点にする (上下の判定を素直に書くため)
    override var isFlipped: Bool { true }

    // その場所がどの端か。真ん中なら nil
    private func edge(at point: NSPoint) -> SplitEdge? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let x = point.x / bounds.width
        let y = point.y / bounds.height
        // 角では、より端に近い方を採る
        let candidates: [(SplitEdge, CGFloat)] = [
            (.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }),
              nearest.1 < Self.band else { return nil }
        return nearest.0
    }

    private func half(for edge: SplitEdge) -> NSRect {
        let w = bounds.width, h = bounds.height
        switch edge {
        case .left:   return NSRect(x: 0, y: 0, width: w / 2, height: h)
        case .right:  return NSRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top:    return NSRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return NSRect(x: 0, y: h / 2, width: w, height: h / 2)
        }
    }

    // 引っ張られてきたものを見て、染めるか決める
    private func evaluate(_ sender: NSDraggingInfo) -> SplitEdge? {
        guard let manager,
              let id = sender.draggingPasteboard.string(forType: .string),
              manager.canAcceptSplitDrop(draggedID: id) else { return nil }
        return edge(at: convert(sender.draggingLocation, from: nil))
    }

    private func show(_ edge: SplitEdge?) {
        // 染めの出し入れに、CALayer 既定のふわっとした動きを付けない
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let edge {
            let gold = NSColor(Deco.gold)
            highlight.backgroundColor = gold.withAlphaComponent(0.22).cgColor
            highlight.borderColor = gold.cgColor
            highlight.borderWidth = 2
            highlight.frame = half(for: edge)
            highlight.isHidden = false
        } else {
            highlight.isHidden = true
        }
        CATransaction.commit()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let edge = evaluate(sender)
        show(edge)
        return edge == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let edge = evaluate(sender)
        show(edge)
        return edge == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        show(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let edge = evaluate(sender)
        show(nil)
        guard let edge, let manager,
              let id = sender.draggingPasteboard.string(forType: .string) else { return false }
        return manager.acceptSplitDrop(draggedID: id, on: edge)
    }
}
