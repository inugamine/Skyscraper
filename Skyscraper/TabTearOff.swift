//
//  TabTearOff.swift
//  Skyscraper
//
//  タブを引っ張って千切る (窓の外へ落とすと新しい窓になる)。
//
//  ── なぜ AppKit まで降りるのか ──
//  SwiftUI の .onDrag / .draggable には「どこにも落とされなかった」を知る手段が無い。
//  macOS 26 の onDragSessionUpdated(_:) も、試した限り一度も呼ばれなかった (2026-07 実測)。
//  AppKit の NSDraggingSource なら draggingSession(_:endedAt:operation:) で
//  「誰も受け取らなかった」と「放した場所」の両方が取れる。
//
//  ── 行の上に板は敷かない ──
//  行のクリック・ホバー・×・右クリックは全部 SwiftUI の側にある。
//  上に NSView を重ねて受けるとそれらと食い合うので、TitlebarClickArea と同じ手を使う。
//  窓に届くマウスを手前で見張り、タブの行の上で押されて 5pt 動いた時だけ
//  こちらでドラッグを始める。どの行の上かは SwiftUI のホバーに教えてもらう。
//
//  ── 落とす側はこれまで通り ──
//  運ぶ中身は今までと同じ「タブの UUID の文字列」なので、
//  並べ替えと窓またぎの受け口 (TabDropDelegate / TabStripDropDelegate) は一切変えていない。
//
//  ── 千切る条件 ──
//  誰も受け取らず、マウスを放して終わった時 (Esc での取り消しではない)。
//  放した場所は問わない。Skyscraper の窓の上 (ページの上など) でも千切る
//

import SwiftUI
import AppKit
import Combine

// MARK: - 新しい窓の目印

// 千切って生まれた窓を、放した場所へ運ぶための目印。
// 窓に載った瞬間に、預かっている置き場所があれば当てはめる
struct TearOffWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> TearOffWindowAnchorView { TearOffWindowAnchorView() }
    func updateNSView(_ view: TearOffWindowAnchorView, context: Context) {}
}

final class TearOffWindowAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        TabTearOff.shared.placeIfPending(window)
    }
}

// MARK: - 見張り役

final class TabTearOff: NSObject, ObservableObject, NSDraggingSource {
    static let shared = TabTearOff()

    // 引っ張りに化けるまでの遊び
    private static let dragThreshold: CGFloat = 5

    private var monitor: Any?

    // 今マウスが乗っている行。SwiftUI の側 (DraggableTabRow) が教えてくる。
    // point は行の中での位置 (左上が原点)、size は行の大きさ
    private weak var hoveredTab: Tab?
    private weak var hoveredManager: TabManager?
    private var hoverPoint: CGPoint = .zero
    private var hoverSize: CGSize = .zero

    // 行の上で押されたまま、まだ引っ張りに化けていない一件
    private weak var pressedTab: Tab?
    private weak var pressedManager: TabManager?
    private var pressPoint: CGPoint = .zero
    private var pressSize: CGSize = .zero
    private var pressLocation: NSPoint = .zero
    private var pressWindowNumber = 0

    // タブを引っ張っている最中か。
    // ページの端へ落として分割する受け皿 (SplitView.swift) が、これを見て出入りする
    @Published private(set) var isDragging = false

    // 引っ張っている最中のタブと、その持ち主
    private weak var draggedTab: Tab?
    private weak var sourceManager: TabManager?

    // 次に生まれる窓の置き場所。
    // 窓を開くのは SwiftUI なので、こちらからは「次に載った目印」に渡すしか無い
    // (TabManager.pendingAdoption と同じ預かり所の手)
    private struct Placement {
        let dropPoint: NSPoint
        let size: NSSize?
        // 全画面の窓から千切った。新しい窓も全画面にする
        let fullScreen: Bool
        let requestedAt: Date
    }
    private var pendingPlacement: Placement?

    // MARK: どの行の上に居るか

    // 「どの行を掴んだか」は SwiftUI に訊く。
    //
    // 最初は行の下に NSView の目印を敷いて、その枠で当たりを見ていた。
    // ところが SwiftUI が置く NSView の枠は当てにならず、
    // どの行を掴んでも一番上のタブを掴んだことになった (2026-11 実測)。
    // ホバーは SwiftUI 自身が配っているので、行の取り違えが起きない
    func hover(_ tab: Tab, in manager: TabManager, at point: CGPoint, size: CGSize) {
        hoveredTab = tab
        hoveredManager = manager
        hoverPoint = point
        hoverSize = size
        installMonitorIfNeeded()
    }

    func hoverEnded(_ tab: Tab) {
        if hoveredTab === tab { hoveredTab = nil }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            // ドラッグを始めた一発だけ飲み込む。それ以外はそのまま流す
            return self.handle(event) ? nil : event
        }
    }

    // MARK: マウスの見張り

    // true を返すとその出来事を飲み込む
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pressedTab = nil
            // 押下がこちらへ届く＝ドラッグはもう終わっている。
            // 終了の知らせを取りこぼしても、受け皿を出しっぱなしにしない
            if isDragging { isDragging = false }
            // ⌃クリックは右クリック扱い (メニューが出る) なので手を出さない
            guard !event.modifierFlags.contains(.control),
                  let window = event.window,
                  let tab = hoveredTab,
                  let manager = hoveredManager else { return false }
            // 押されたのが、その行の居る窓であること
            if let host = manager.hostWindow, host !== window { return false }
            // 盤 (タブ検索・館内案内板) が被さっている間は、下の行を掴ませない
            if manager.isTabSearchVisible || manager.isDirectoryVisible { return false }
            // × の上で押した分は閉じる操作に任せる (ピン留め中は × が無い)
            if !tab.isPinned, hoverPoint.x > hoverSize.width - 36 { return false }
            // 音の印 (ミュートの入切) の上も同じ
            if tab.isMuted || tab.isPlayingAudio, hoverPoint.x > 36, hoverPoint.x < 60 { return false }

            pressedTab = tab
            pressedManager = manager
            pressPoint = hoverPoint
            pressSize = hoverSize
            pressLocation = event.locationInWindow
            pressWindowNumber = window.windowNumber
            // 押下そのものは流す (選択は SwiftUI の側の仕事)
            return false

        case .leftMouseDragged:
            guard let tab = pressedTab,
                  let manager = pressedManager,
                  event.windowNumber == pressWindowNumber else { return false }
            let dx = event.locationInWindow.x - pressLocation.x
            let dy = event.locationInWindow.y - pressLocation.y
            guard hypot(dx, dy) >= Self.dragThreshold else { return false }
            pressedTab = nil
            return beginDrag(tab, in: manager, with: event)

        case .leftMouseUp:
            pressedTab = nil
            return false

        default:
            return false
        }
    }

    // MARK: ドラッグの開始

    private func beginDrag(_ tab: Tab, in manager: TabManager, with event: NSEvent) -> Bool {
        guard let window = event.window,
              let view = window.contentView,
              pressSize.width > 0, pressSize.height > 0 else { return false }

        // 札を出す場所。押した時の行の枠を、窓の中身の座標で組み立てる。
        // pressPoint は左上が原点なので、中身の向き (上下) に合わせる
        let pressed = view.convert(pressLocation, from: nil)
        let frame = NSRect(
            x: pressed.x - pressPoint.x,
            y: view.isFlipped ? pressed.y - pressPoint.y
                              : pressed.y - (pressSize.height - pressPoint.y),
            width: pressSize.width,
            height: pressSize.height
        )

        // 運ぶ中身はタブの UUID の文字列。SwiftUI の受け口 (.onDrop(of: [.text])) がそのまま読める
        let item = NSPasteboardItem()
        item.setString(tab.id.uuidString, forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(
            frame,
            contents: previewImage(for: tab, size: pressSize, scale: window.backingScaleFactor)
        )

        draggedTab = tab
        sourceManager = manager
        isDragging = true
        let session = view.beginDraggingSession(with: [dragItem], event: event, source: self)
        // 受け取り手が無ければ千切るので、札を元の場所へ滑って戻らせない
        session.animatesToStartingPositionsOnCancelOrFail = false

        // SwiftUI は押下を受け取ったままで、放した知らせはもう来ない
        // (ドラッグが始まると、マウスはシステムが持っていく)。
        // 宙に浮いた押下を残さないよう、行の外で放したことにして畳んでおく
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: -10_000, y: -10_000),
            modifierFlags: [],
            timestamp: event.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: 1,
            pressure: 0
        ) {
            window.sendEvent(up)
        }
        return true
    }

    // 引っ張っている間に指の下へ出す札。行と同じ大きさ・同じ意匠で描く
    private func previewImage(for tab: Tab, size: NSSize, scale: CGFloat) -> NSImage {
        let renderer = ImageRenderer(
            content: TabDragPreview(title: tab.pageTitle,
                                    favicon: tab.favicon,
                                    isPinned: tab.isPinned)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = scale
        return renderer.nsImage ?? NSImage(size: size)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 他のアプリには渡さない。
        // 渡せることにすると、テキストエディットなどが UUID の文字列を受け取ってしまい、
        // 「誰も受け取らなかった」が成り立たなくなる
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let tab = draggedTab
        let manager = sourceManager
        draggedTab = nil
        sourceManager = nil
        isDragging = false

        // どこかが受け取った (並べ替え・他の窓へ移した)。こちらの出番ではない
        guard operation == [], let tab, let manager else { return }
        // ボタンがまだ押されている＝放して終わったのではない (Esc での取り消し)
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        // 放した場所は問わない。Skyscraper の窓の上でも千切る——
        // 全画面の窓だと「窓の外」がそもそも無い
        manager.moveTabToNewWindow(tab, dropPoint: screenPoint)
    }

    // MARK: 新しい窓の置き場所

    // 千切る時に TabManager から呼ばれる。次に生まれる窓の置き場所を預かる。
    // size は元の窓の大きさ (Safari と同じく、千切った窓は元と同じ大きさで出す)
    func requestPlacement(dropPoint: NSPoint, size: NSSize?, fullScreen: Bool) {
        pendingPlacement = Placement(dropPoint: dropPoint, size: size,
                                     fullScreen: fullScreen, requestedAt: Date())
    }

    func placeIfPending(_ window: NSWindow) {
        guard let placement = pendingPlacement else { return }
        pendingPlacement = nil
        // 窓が開かなかった時の残り物を、後の無関係な窓に当てない
        guard Date().timeIntervalSince(placement.requestedAt) < 3 else { return }
        if placement.fullScreen {
            // 全画面へは、窓が画面に出てからでないと入れない。一拍おく
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
            return
        }
        apply(placement, to: window)
        // SwiftUI が窓の位置を後から決め直すことがあるので、一拍おいてもう一度
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.apply(placement, to: window)
        }
    }

    private func apply(_ placement: Placement, to window: NSWindow) {
        var frame = window.frame
        if let size = placement.size { frame.size = size }
        // 掴んでいた札 (帯の一番上の行あたり) が指の下に来るように置く。
        // 窓の座標は左下が原点
        frame.origin = NSPoint(
            x: placement.dropPoint.x - 100,
            y: placement.dropPoint.y + 140 - frame.height
        )
        // 画面の使える範囲からはみ出さないように寄せる
        let screen = NSScreen.screens.first { $0.frame.contains(placement.dropPoint) }
            ?? window.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX),
                                 max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, visible.minY),
                                 max(visible.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
    }
}

// MARK: - 引っ張っている間の札

// DecoTabRow の見た目だけを写したもの (選択中の行と同じ、金の六角枠)。
// 本物の行を使い回さないのは、あちらがホバーやメニューまで抱えているから
private struct TabDragPreview: View {
    let title: String
    let favicon: NSImage?
    let isPinned: Bool

    private let shape = Hexagon(inset: 9)

    var body: some View {
        HStack(spacing: 6) {
            FaviconBadge(image: favicon, isPinned: isPinned)
            (title.isEmpty ? Text("New Tab") : Text(verbatim: title))
                .font(.system(size: 12, design: .serif))
                .foregroundColor(Deco.cream)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Deco.ink))
        .overlay(shape.stroke(Deco.gold, lineWidth: 1))
        .opacity(0.92)
    }
}
