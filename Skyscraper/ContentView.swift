//
//  ContentView.swift
//  Skyscraper
//
//  Created by inugaminé on 2026/07/11.
//

import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

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

// 半円のサンバースト（扇）。下辺中央を要にして上に開く
struct Sunburst: Shape {
    var rays: Int = 5                     // 放射線の本数
    var arcRatios: [CGFloat] = [1.0, 0.62] // 円弧の半径比（外側から）

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width / 2, rect.height)

        // 円弧（180°→360°、上側を通る）
        for ratio in arcRatios {
            let r = radius * ratio
            p.move(to: CGPoint(x: center.x - r, y: center.y))
            p.addArc(center: center, radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(360),
                     clockwise: false)
        }

        // 要から伸びる放射線（両端は除き、等間隔に並べる）
        for i in 1...rays {
            let angle = Angle.degrees(180 + 180 * Double(i) / Double(rays + 1))
            let end = CGPoint(
                x: center.x + radius * cos(angle.radians),
                y: center.y + radius * sin(angle.radians)
            )
            p.move(to: center)
            p.addLine(to: end)
        }
        return p
    }
}

// 扇を横に連ねた飾り罫（フリーズ）。ロゴ下の区切りに使う。
// 各扇は根元がすぼまったパルメット形（釣鐘を逆さにした輪郭）
struct FanFrieze: Shape {
    var fans: Int = 5       // 手前の段の扇の個数
    var rays: Int = 4       // 各扇の放射線の本数
    var overlap: CGFloat = 0.62  // 扇の幅（step に対する半径の比）
    var tiers: Int = 1      // 段数（2 で鱗紋になる）

    // 弧の振り幅。深く回して胴を膨らませる（両端は中心から sin150°=0.5r 下）
    private let startDeg = 150.0
    private let endDeg   = 390.0
    // 要（根元）は円の中心から半径×1.15 下。弧端（0.5r）との差が絞りの深さになる
    private let pinchDrop: CGFloat = 1.15

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step = rect.width / CGFloat(max(fans, 1))
        // 扇一つの全高は (1 + pinchDrop) × 半径。段の持ち上げも足して果に収める
        let lift: CGFloat = 0.85   // 奧の段の持ち上げ（半径比）。絞った根元が谷に深く収まる
        let unitH = 1 + pinchDrop
        let maxRadius = tiers > 1 ? rect.height / (unitH + lift) : rect.height / unitH
        let radius = min(step * overlap, maxRadius)

        func arcPoint(_ c: CGPoint, _ deg: Double) -> CGPoint {
            let a = Angle.degrees(deg).radians
            return CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
        }

        func drawFan(base: CGPoint) {
            // 円の中心は要の真上
            let c = CGPoint(x: base.x, y: base.y - radius * pinchDrop)
            let left  = arcPoint(c, startDeg)
            let right = arcPoint(c, endDeg)
            // 両脇は )( のように内に凹む曲線。制御点を軸の近く・低めに置くと、
            // 要からはほぼ垂直に立ち上がり、上で外へ翻る
            let waistL = CGPoint(x: base.x - radius * 0.06, y: base.y - radius * 0.50)
            let waistR = CGPoint(x: base.x + radius * 0.06, y: base.y - radius * 0.50)
            p.move(to: base)
            p.addQuadCurve(to: left, control: waistL)
            p.addArc(center: c, radius: radius,
                     startAngle: .degrees(startDeg), endAngle: .degrees(endDeg),
                     clockwise: false)
            p.addQuadCurve(to: base, control: waistR)
            // 放射線：要から弧の全域へ。輪郭と同じ絞りに沿わせて、
            // 根元で束ねられてから外へ開く曲線にする
            for i in 1...rays {
                let t = Double(i) / Double(rays + 1)
                let end = arcPoint(c, startDeg + (endDeg - startDeg) * t)
                let control = CGPoint(
                    x: base.x + (end.x - base.x) * 0.10,
                    y: base.y - radius * 0.50
                )
                p.move(to: base)
                p.addQuadCurve(to: end, control: control)
            }
        }

        // 奧の段：半歩ずらして一段高く
        if tiers > 1 {
            for f in 0..<(fans - 1) {
                drawFan(base: CGPoint(x: rect.minX + step * (CGFloat(f) + 1.0),
                                      y: rect.maxY - radius * lift))
            }
        }

        // 手前の段
        for f in 0..<fans {
            drawFan(base: CGPoint(x: rect.minX + step * (CGFloat(f) + 0.5),
                                  y: rect.maxY))
        }
        return p
    }
}

// MARK: - ロビーの額縁飾り

// 四隅の飾り。入れ子のL字罫＋対角に降りる段々（ビルの写し）
// 左上向きに描き、他の隅は反転で使い回す
struct CornerOrnament: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = min(rect.width, rect.height)

        // 入れ子のL字罫（外から3本）
        for i in 0..<3 {
            let inset = s * 0.10 * CGFloat(i)
            p.move(to: CGPoint(x: inset, y: s))
            p.addLine(to: CGPoint(x: inset, y: inset))
            p.addLine(to: CGPoint(x: s, y: inset))
        }

        // 対角に降りる階段（段々ビルのモチーフを隅に落とし込む）
        let step = s * 0.11
        var pt = CGPoint(x: s * 0.92, y: s * 0.36)
        p.move(to: pt)
        for _ in 0..<4 {
            pt.x -= step
            p.addLine(to: pt)
            pt.y += step
            p.addLine(to: pt)
        }
        return p
    }
}

// ロビー全面に被せる額縁。二重の枠と四隅の飾り
struct LobbyFrame: View {
    private let corner: CGFloat = 58
    private let pad: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .stroke(Deco.gold.opacity(0.6), lineWidth: 1.2)
                    .padding(12)
                Rectangle()
                    .stroke(Deco.faintGold, lineWidth: 0.8)
                    .padding(20)

                ornament(flipX: false, flipY: false)
                    .position(x: pad + corner / 2, y: pad + corner / 2)
                ornament(flipX: true, flipY: false)
                    .position(x: geo.size.width - pad - corner / 2, y: pad + corner / 2)
                ornament(flipX: false, flipY: true)
                    .position(x: pad + corner / 2, y: geo.size.height - pad - corner / 2)
                ornament(flipX: true, flipY: true)
                    .position(x: geo.size.width - pad - corner / 2,
                              y: geo.size.height - pad - corner / 2)
            }
        }
        // 飾りはクリックを拾わない（下のボタン操作を邪魔しない）
        .allowsHitTesting(false)
    }

    private func ornament(flipX: Bool, flipY: Bool) -> some View {
        CornerOrnament()
            .stroke(
                LinearGradient(colors: [Deco.gold, Deco.gold.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
            .frame(width: corner, height: corner)
            .scaleEffect(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
    }
}

// 扇の両脇に置く、外に向かって降りる段々の袖。
// 高い辺が左（扇寄り）の右袖を描き、左袖は反転で使い回す
struct SteppedWing: Shape {
    var steps: Int = 4
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sw = rect.width / CGFloat(max(steps, 1))
        let sh = rect.height / CGFloat(max(steps, 1))
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        var x = rect.minX
        var y = rect.minY
        for _ in 0..<max(steps, 1) {
            x += sw
            p.addLine(to: CGPoint(x: x, y: y))
            y += sh
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }
}

// ロビー下端中央の扇飾り。既存の Sunburst を流用し、
// 両脇に段々の袖、要にダイヤを一粒置く
struct LobbyBottomFan: View {
    // 袖のグラデーション：内（扇寄り）が明るく、外に向かって沈む。
    // 左袖は反転で描くので、同じ定義のまま左右対称になる
    private let wingGradient = LinearGradient(
        colors: [Deco.gold, Deco.gold.opacity(0.25)],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                SteppedWing(steps: 4)
                    .stroke(wingGradient, lineWidth: 1)
                    .frame(width: 68, height: 32)
                    .scaleEffect(x: -1)

                Sunburst(rays: 7, arcRatios: [1.0, 0.62])
                    .stroke(
                        // 要（下）を明るく、先端（上）を闇に沈ませる
                        LinearGradient(colors: [Deco.gold.opacity(0.30), Deco.gold],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .frame(width: 200, height: 68)

                SteppedWing(steps: 4)
                    .stroke(wingGradient, lineWidth: 1)
                    .frame(width: 68, height: 32)
            }

            Rectangle()
                .stroke(Deco.gold, lineWidth: 1)
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(45))
        }
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
        // 保存済みがあれば読み込む。無ければ空から始める
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        } else {
            bookmarks = []
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

    // ドラッグでの並べ替え：draggedID の項目を targetID の前または後ろに挿す
    func move(draggedID: String, target targetID: UUID, after: Bool) {
        guard draggedID != targetID.uuidString else { return }
        var arr = bookmarks
        guard let from = arr.firstIndex(where: { $0.id.uuidString == draggedID }) else { return }
        let moved = arr.remove(at: from)
        if let base = arr.firstIndex(where: { $0.id == targetID }) {
            arr.insert(moved, at: after ? base + 1 : base)
        } else {
            arr.append(moved)
        }
        bookmarks = arr
    }
}

// MARK: - コンテキストメニューを引き受ける WKWebView

// 素の WKWebView は、右クリックの「画像をダウンロード」「リンク先のファイルをダウンロード」を
// 選んでも WKDownloadDelegate を一切呼ばず、内部で保存先が決まらないまま
// "Could not create a sandbox extension for ''" を吐いて黙って失敗する（WebKit の既知の不具合）。
// そこで右クリック位置を控えておき、該当メニュー項目の飛び先を自前の処理に差し替えて、
// startDownload(using:) で既存のダウンロード経路（NSSavePanel の流れ）に合流させる。
final class SkyscraperWebView: WKWebView {
    // 直近の右クリック位置（CSS ピクセル・左上原点）。elementFromPoint に渡す
    private var lastRightClick: CGPoint = .zero

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // ビューの上下向きとページ拡大率を JS 座標系に合わせる
        let topY = isFlipped ? p.y : bounds.height - p.y
        lastRightClick = CGPoint(x: p.x / pageZoom, y: topY / pageZoom)
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierDownloadImage":
                item.target = self
                item.action = #selector(downloadImageAtLastClick(_:))
            case "WKMenuItemIdentifierDownloadLinkedFile":
                item.target = self
                item.action = #selector(downloadLinkAtLastClick(_:))
            default:
                break
            }
        }
    }

    @objc private func downloadImageAtLastClick(_ sender: Any?) {
        // クリック位置から親を辿って画像を探す。<img> が無ければ背景画像も見る
        let js = """
        (() => {
            let el = document.elementFromPoint(\(lastRightClick.x), \(lastRightClick.y));
            while (el) {
                if (el.tagName === 'IMG') { return el.currentSrc || el.src || null; }
                const bg = window.getComputedStyle(el).backgroundImage || '';
                const m = bg.match(/url\\(["']?([^"')]+)["']?\\)/);
                if (m) { return m[1]; }
                el = el.parentElement;
            }
            return null;
        })();
        """
        startDownload(fromJS: js)
    }

    @objc private func downloadLinkAtLastClick(_ sender: Any?) {
        let js = """
        (() => {
            const el = document.elementFromPoint(\(lastRightClick.x), \(lastRightClick.y));
            const a = el ? el.closest('a[href]') : null;
            return a ? a.href : null;
        })();
        """
        startDownload(fromJS: js)
    }

    private func startDownload(fromJS js: String) {
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let urlString = result as? String,
                  let url = URL(string: urlString) else { return }
            self.startDownload(using: URLRequest(url: url)) { download in
                // 保存先の決定は Tab（navigationDelegate）の既存処理に任せる
                download.delegate = self.navigationDelegate as? WKDownloadDelegate
            }
        }
    }
}

// MARK: - WKWebView ラッパー

// SwiftUI と WKWebView の間に挟む器。
// 全画面再生に入ると、WebKit は WKWebView を別ウィンドウへ引っこ抜き、
// 終わったら元の親に戻す。親が SwiftUI の管理下だと、SwiftUI は
// 「子が居ない」と見て即座に引き戻し、WebKit は梯子を外されて
// 全画面を諦める（一瞬だけ大画面になって戻る症状）。
// SwiftUI にはこの器だけを見せ、WKWebView の出入りは見せない。
final class WebViewContainer: NSView {
    // 裏タブの WebView がクリックを拾わないよう、AppKit の層でも遮断する
    var isInteractive = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }
}

struct WebView: NSViewRepresentable {
    let webView: WKWebView
    var isInteractive: Bool = true

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.isInteractive = isInteractive
        mount(webView, in: container)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.isInteractive = isInteractive

        // ここでは WKWebView の親子関係に一切手を出さない。
        //
        // 全画面の出入りでは WebKit が自分で親を付け替え、終わったら
        // 元の器に戻す。その途中でこちらが付け直しに行くと、全画面が
        // 即座に中断される（一瞬だけ大画面になって戻る症状）。
        //
        // fullscreenState を見て避けようとしたが、引っこ抜きと
        // 状態の切り替わりには隙間があり、そこを踏むと
        // .notInFullscreen なのに superview が器でない状態を
        // 「迷子」と誤判して引き戻してしまう。
        // 再描画が頻繁なページ（X など）でだけ再現するのはこのせい。
        //
        // 後始末は WebKit の仕事だ。任せる
    }

    // 制約ではなく autoresizing で押さえる。
    // 制約は親を離れた瞬間に外され、戻ってきても復活しない
    private func mount(_ webView: WKWebView, in container: WebViewContainer) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

// MARK: - タブ一枚ぶんの状態

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    // WKWebView は生成後に configuration を読むとコピーが返るため、
    // 設定は必ず生成前に済ませる
    let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // 動画の全画面ボタン（Fullscreen API）を使えるようにする。
        // macOS の WKWebView はこれが既定で無効で、ページが
        // requestFullscreen() を呼んでも黙って拒否される（おかげで
        // YouTube も X も大画面ボタンが無反応になる）
        configuration.preferences.isElementFullscreenEnabled = true
        return SkyscraperWebView(frame: .zero, configuration: configuration)
    }()

    @Published var urlText: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var pageTitle: String = ""
    @Published var isHome: Bool = true
    @Published var addressBarFocusTrigger: Int = 0
    // 音を鳴らしているか（🔊インジケータ用）
    @Published var isPlayingAudio: Bool = false
    // ミュート中か
    @Published var isMuted: Bool = false
    // 疑似大画面（シアター）中か。サイドバーやバー類の隠しに使う
    @Published var isVideoFullscreen: Bool = false

    // ⌘クリックされたリンクを新規タブで開くための連絡先（TabManager が入れる）
    var openInNewTab: ((String) -> Void)?

    private static let mediaStateMessageHandlerName = "skyscraperMediaState"
    private static let fullscreenMessageHandlerName = "skyscraperFullscreen"
    private static let mediaPlaybackObserverScript = WKUserScript(
        source: """
        (() => {
            if (window.__skyscraperMediaObserverInstalled) {
                window.__skyscraperReportMediaState?.(true);
                return;
            }

            window.__skyscraperMediaObserverInstalled = true;
            let lastState = null;
            let scanScheduled = false;
            let reportScheduled = false;
            let muted = false;

            // ── 自動再生の音を黙らせる番人 ──
            // X（Twitter）は「ミュート解除」の設定を覚えていて、スクロールで
            // 次の動画が流れてくるたびに勝手に音を出す。
            // 「利用者が自分の手で外した要素だけ音を許す」規則で押さえ込む。
            // 対象を増やしたければこの配列に足す
            const guardedHosts = ['x.com', 'twitter.com'];
            const autoplayGuard = guardedHosts.some(host =>
                location.hostname === host || location.hostname.endsWith('.' + host)
            );

            // 直近のユーザー操作の時刻。ミュート解除がユーザー由来かページ由来かは
            // これで見分ける（isTrusted なので JS からは詐称できない）
            let lastGestureAt = -Infinity;
            const gestureWindow = 1000;
            const userJustActed = () => Date.now() - lastGestureAt < gestureWindow;
            if (autoplayGuard) {
                ['pointerdown', 'mousedown', 'click', 'keydown'].forEach(eventName => {
                    document.addEventListener(eventName, event => {
                        if (event.isTrusted) { lastGestureAt = Date.now(); }
                    }, true);
                });

                // ── 疑似大画面（シアター）──
                // X は本物の全画面に入ると、イベント・getter・Promise・
                // resize・焦点を全て偽装しても約150msでプレイヤーの DOM を
                // 作り直し、全画面中の要素が消えて強制解除される
                // （経路はページ側 JS から偽装できない場所にある）。
                // なので本物の全画面は使わず、requestFullscreen を横取りして
                // CSS で要素をウィンドウいっぱいに広げる。ページには何も
                // 起きていないので、原理的に気付かれない。
                // ウィンドウ自体の全画面化はアプリ側（skyscraperFullscreen）が担う
                const theaterStyle = document.createElement('style');
                theaterStyle.textContent =
                    '.__skyscraper-theater { position: fixed !important; inset: 0 !important; ' +
                    'width: 100vw !important; height: 100vh !important; ' +
                    'max-width: none !important; max-height: none !important; ' +
                    'margin: 0 !important; padding: 0 !important; transform: none !important; ' +
                    'border-radius: 0 !important; background: #000 !important; ' +
                    'z-index: 2147483647 !important; } ' +
                    '.__skyscraper-theater video { width: 100% !important; height: 100% !important; ' +
                    'object-fit: contain !important; } ' +
                    '.__skyscraper-theater-ancestor { transform: none !important; ' +
                    'filter: none !important; backdrop-filter: none !important; ' +
                    'perspective: none !important; contain: none !important; ' +
                    'will-change: auto !important; z-index: auto !important; ' +
                    'overflow: visible !important; } ' +
                    '.__skyscraper-theater-hidden { visibility: hidden !important; } ' +
                    '.__skyscraper-theater-nocursor, .__skyscraper-theater-nocursor * { ' +
                    'cursor: none !important; }';
                (document.head || document.documentElement).appendChild(theaterStyle);

                let theaterTarget = null;
                let theaterAncestors = [];
                let theaterHidden = [];
                let theaterResumeCleanup = null;
                let theaterScrollX = 0;
                let theaterScrollY = 0;
                // 動画への通り道（先祖の連なり）に居ない兄弟を隠す。
                // 何度呼んでも良い作り（既に隠した奴は飛ばす）にしてあり、
                // 在場中に React が作り直した・新しく生やした要素にも
                // MutationObserver 経由で採用される
                const theaterHide = () => {
                    if (!theaterTarget) { return; }
                    let onPath = theaterTarget;
                    let parent = theaterTarget.parentElement;
                    while (parent && onPath !== document.body) {
                        for (const sibling of parent.children) {
                            if (sibling !== onPath
                                && !sibling.classList.contains('__skyscraper-theater-hidden')) {
                                sibling.classList.add('__skyscraper-theater-hidden');
                                theaterHidden.push(sibling);
                            }
                        }
                        onPath = parent;
                        parent = parent.parentElement;
                    }
                };

                // ── カーソルの自動消灯 ──
                // 映画館方式：止まって2.5秒で消え、動かせば即座に戻る。
                // 一時停止中は消さない（コントロール操作の邪魔になる）
                let theaterCursorTimer = null;
                const theaterCursorHide = () => {
                    if (!theaterTarget) { return; }
                    const video = theaterTarget.querySelector('video');
                    if (video && video.paused) { return; }
                    theaterTarget.classList.add('__skyscraper-theater-nocursor');
                };
                const theaterCursorShow = () => {
                    clearTimeout(theaterCursorTimer);
                    theaterCursorTimer = null;
                    if (!theaterTarget) { return; }
                    theaterTarget.classList.remove('__skyscraper-theater-nocursor');
                    theaterCursorTimer = setTimeout(theaterCursorHide, 2500);
                };
                window.addEventListener('mousemove', () => {
                    if (theaterTarget) { theaterCursorShow(); }
                }, true);

                const theaterEnter = element => {
                    theaterTarget = element;
                    // 退場時に戻すため、今のスクロール位置を控える
                    theaterScrollX = window.scrollX;
                    theaterScrollY = window.scrollY;
                    element.classList.add('__skyscraper-theater');
                    // position: fixed は、先祖に transform 等を持つ要素が居ると
                    // ビューポートではなくその先祖基準になる（X はセルの配置に
                    // transform を使う）。在場中だけ先祖全員の transform ・
                    // z-index などを無効化して、fixed を本来の意味に戻す
                    theaterAncestors = [];
                    let node = element.parentElement;
                    while (node && node !== document.documentElement) {
                        node.classList.add('__skyscraper-theater-ancestor');
                        theaterAncestors.push(node);
                        node = node.parentElement;
                    }
                    // X のナビや浮きボタンは別層の fixed で、z-index では
                    // 確実に勝てない。勝負せず、道の外の兄弟を隠す。
                    // レイアウトは動かないので、剥がせば完全に元通り
                    theaterHidden = [];
                    theaterHide();
                    // X は全画面移行の前置きとして動画を一時停止することがある。
                    // 本物の全画面は永遠に来ないので、再開の合図も永遠に来ない。
                    // 入場時に起こし、直後（移行処理の残り）の一時停止も
                    // 1.2 秒だけ見張って起こし直す。
                    // （その後の一時停止は本人の操作と見なして触らない）
                    const theaterVideo = element.querySelector('video');
                    if (theaterVideo) {
                        const resume = () => { theaterVideo.play().catch(() => {}); };
                        const onPause = () => resume();
                        theaterVideo.addEventListener('pause', onPause, true);
                        const disarm = setTimeout(() => {
                            theaterVideo.removeEventListener('pause', onPause, true);
                        }, 1200);
                        theaterResumeCleanup = () => {
                            clearTimeout(disarm);
                            theaterVideo.removeEventListener('pause', onPause, true);
                        };
                        if (theaterVideo.paused && !theaterVideo.ended) { resume(); }
                    }
                    // カーソルの消灯タイマーを回し始める
                    theaterCursorShow();
                    window.webkit?.messageHandlers?.skyscraperFullscreen?.postMessage(true);
                };
                const theaterExit = () => {
                    if (!theaterTarget) { return; }
                    theaterResumeCleanup?.();
                    theaterResumeCleanup = null;
                    clearTimeout(theaterCursorTimer);
                    theaterCursorTimer = null;
                    theaterTarget.classList.remove('__skyscraper-theater-nocursor');
                    theaterTarget.classList.remove('__skyscraper-theater');
                    theaterTarget = null;
                    theaterAncestors.forEach(node =>
                        node.classList.remove('__skyscraper-theater-ancestor'));
                    theaterAncestors = [];
                    theaterHidden.forEach(node =>
                        node.classList.remove('__skyscraper-theater-hidden'));
                    theaterHidden = [];
                    // 先祖のスタイルを戻した後で、スクロール位置も元に戻す
                    window.scrollTo(theaterScrollX, theaterScrollY);
                    window.webkit?.messageHandlers?.skyscraperFullscreen?.postMessage(false);
                };
                window.__skyscraperExitTheater = theaterExit;

                const origRequestFullscreen = Element.prototype.requestFullscreen;
                Element.prototype.requestFullscreen = function () {
                    // X のボタンは fullscreenElement（常に null）を見て毎回
                    // 「入る」を呼ぶので、ここでトグルにする
                    if (theaterTarget) { theaterExit(); } else { theaterEnter(this); }
                    // 解決を渡すと X が全画面用の組み直しを始めて要素を消すので、
                    // 永遠に確定しない Promise で黙らせる
                    return new Promise(() => {});
                };

                // Esc で退場（X には渡さない）
                document.addEventListener('keydown', event => {
                    if (event.key === 'Escape' && theaterTarget) {
                        event.stopImmediatePropagation();
                        theaterExit();
                    }
                }, true);

                // 在場中は背後のページをスクロールさせない。
                // overflow: hidden はスクロール位置を 0 に壊すので使わず、
                // wheel を飲み込むだけにする
                window.addEventListener('wheel', event => {
                    if (theaterTarget) { event.preventDefault(); }
                }, { passive: false, capture: true });

                // 在場中の DOM 変化の見張り。
                // ・対象ノードが差し替えで消えたら、道連れにせず畳む
                // ・新しく生えた・作り直された要素は即座に隠し直す
                //   （クリックで X が右欄などを再生成しても浮いてこない）
                new MutationObserver(() => {
                    if (!theaterTarget) { return; }
                    if (!theaterTarget.isConnected) { theaterExit(); return; }
                    theaterHide();
                }).observe(document.documentElement, { childList: true, subtree: true });
            }

            // 全画面再生の最中は、番人は完全に手を引く。
            // ここで muted を触ると volumechange が飛び、X のプレイヤーが
            // UI を組み直して全画面中の要素を DOM から差し替える。
            // 要素が消えれば WebKit は仕様通り全画面を解除する
            const inFullscreen = () =>
                !!(document.fullscreenElement || document.webkitFullscreenElement);

            // コンソールから番人を止められる非常停止（診断用）。
            // window.__skyscraperDisableAutoplayGuard = true で即座に黙る
            const guardActive = () =>
                autoplayGuard
                && !window.__skyscraperDisableAutoplayGuard
                && !inFullscreen();

            // ページと張り合って無限に往復しないための安全弁
            const correctionLimit = 30;
            const silence = element => {
                if (!guardActive()) { return; }
                element.__skyscraperCorrections = (element.__skyscraperCorrections || 0) + 1;
                if (element.__skyscraperCorrections > correctionLimit) { return; }
                if (!element.muted) { element.muted = true; }
            };

            const applyMuted = () => {
                document.querySelectorAll('audio, video').forEach(element => {
                    if (muted) {
                        element.muted = true;
                    } else if (!autoplayGuard || element.__skyscraperUnmuteApproved) {
                        // 番人が働く場では、本人が外した要素にだけ音を戻す
                        element.muted = false;
                    }
                });
            };

            const currentState = () => {
                return Array.from(document.querySelectorAll('audio, video')).some(element => {
                    return !element.paused && !element.ended && !element.muted && element.volume > 0;
                });
            };

            const report = (force = false) => {
                const isPlayingAudio = currentState();
                if (!force && isPlayingAudio === lastState) { return; }
                lastState = isPlayingAudio;
                window.webkit?.messageHandlers?.skyscraperMediaState?.postMessage(isPlayingAudio);
            };

            const scheduleReport = () => {
                if (reportScheduled) { return; }
                reportScheduled = true;
                setTimeout(() => {
                    reportScheduled = false;
                    report();
                }, 150);
            };

            const attach = element => {
                if (element.__skyscraperMediaObserverAttached) { return; }
                element.__skyscraperMediaObserverAttached = true;
                // ミュート中に現れた・再生を始めた要素にもミュートを適用する
                if (muted) { element.muted = true; }
                element.addEventListener('play', () => { if (muted) { element.muted = true; } }, true);

                if (autoplayGuard) {
                    // 現れたばかりの要素は、まず黙らせる
                    if (!muted && !element.__skyscraperUnmuteApproved) { silence(element); }

                    // 再生開始：許可の無い要素には音を出させない
                    const enforce = () => {
                        if (muted || element.__skyscraperUnmuteApproved) { return; }
                        silence(element);
                    };
                    ['play', 'playing', 'loadeddata'].forEach(eventName => {
                        element.addEventListener(eventName, enforce, true);
                    });
                    // 中身が入れ替わったら安全弁を戻す（要素は使い回される）
                    element.addEventListener('emptied', () => {
                        element.__skyscraperCorrections = 0;
                    }, true);

                    // ミュート状態が変わった瞬間の見張り
                    element.addEventListener('volumechange', () => {
                        if (muted) { return; }
                        if (element.muted) {
                            // 本人が黙らせたなら許可を取り下げる。
                            // タブミュートなどページ外の都合では取り下げない
                            if (userJustActed()) { element.__skyscraperUnmuteApproved = false; }
                            return;
                        }
                        if (userJustActed()) {
                            // 押した直後の解除＝本人の意思。以後この要素は音を許す
                            element.__skyscraperUnmuteApproved = true;
                            element.__skyscraperCorrections = 0;
                            return;
                        }
                        // 誰も触っていないのに音が開いた＝ページの仕業
                        if (!element.__skyscraperUnmuteApproved) { silence(element); }
                    }, true);
                }

                ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'abort'].forEach(eventName => {
                    element.addEventListener(eventName, scheduleReport, true);
                });
            };

            const scan = () => {
                scanScheduled = false;
                document.querySelectorAll('audio, video').forEach(attach);
                if (muted) { applyMuted(); }
                scheduleReport();
            };

            const scheduleScan = () => {
                if (scanScheduled) { return; }
                scanScheduled = true;
                setTimeout(scan, 250);
            };

            window.__skyscraperReportMediaState = report;
            window.__skyscraperSetMuted = value => {
                muted = !!value;
                applyMuted();
                report(true);
            };
            if (autoplayGuard) {
                // 全画面から戻ってきたら、改めて見張りを立て直す
                ['fullscreenchange', 'webkitfullscreenchange'].forEach(eventName => {
                    document.addEventListener(eventName, () => {
                        if (inFullscreen()) { return; }
                        document.querySelectorAll('audio, video').forEach(element => {
                            if (!muted && !element.__skyscraperUnmuteApproved) { silence(element); }
                        });
                        scheduleReport();
                    }, true);
                });
            }
            new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true });
            document.addEventListener('visibilitychange', scheduleReport, true);
            scan();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private var observers: [NSKeyValueObservation] = []

    init(url: String? = nil) {
        super.init()

        // トラックパッドの2本指スワイプで戻る／進む
        webView.allowsBackForwardNavigationGestures = true
        // Safari の「開発」メニューから Web インスペクタを繋げるようにする。
        // WebKit はこれを明示的に許可しない限り外部からの接続を拒む
        webView.isInspectable = true
        // WKWebView 素の UA だと YouTube などに「古いブラウザ」と誤判定される。
        // 実機 Safari（macOS 27 / Version 27.0）の UA を名乗って回避する。
        // OS 部分の 10_15_7 は Safari 自身が凍結している値なので、これで正しい
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"
        // 広告・トラッカーの遮断ルールを適用（初回はコンパイル後に非同期で効く）
        AdBlocker.shared.apply(to: webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.addUserScript(Self.mediaPlaybackObserverScript)
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Self.mediaStateMessageHandlerName
        )
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Self.fullscreenMessageHandlerName
        )
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                guard let urlText = wv.url?.absoluteString,
                      self?.urlText != urlText else { return }
                self?.urlText = urlText
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoBack = wv.canGoBack }
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoForward = wv.canGoForward }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = wv.isLoading
                // ページ遷移で疑似大画面の CSS ごと消えるので、アプリ側も畳む
                if wv.isLoading, self.isVideoFullscreen {
                    self.setVideoFullscreen(false)
                }
                // ページ遷移後もミュートを貼り直す（スクリプトはページごとに入れ直るため）
                if !wv.isLoading, self.isMuted {
                    wv.evaluateJavaScript("window.__skyscraperSetMuted?.(true);")
                }
            }
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

    // ミュートの切り替え。ページ側のスクリプトが状態を記憶し、
    // 新しいメディア要素にも自動で適用する
    func toggleMute() {
        isMuted.toggle()
        webView.evaluateJavaScript("window.__skyscraperSetMuted?.(\(isMuted));")
    }

    // 疑似大画面の出入り。ページ側（skyscraperFullscreen）から合図が来て、
    // ウィンドウの全画面化も連動させる
    func setVideoFullscreen(_ active: Bool) {
        guard active != isVideoFullscreen else { return }
        isVideoFullscreen = active
        guard let window = webView.window else { return }
        let windowIsFullscreen = window.styleMask.contains(.fullScreen)
        if active != windowIsFullscreen {
            window.toggleFullScreen(nil)
        }
    }

    // ズーム（ページの拡大率を 50%〜300% の範囲で変える）
    func zoomIn()    { setZoom(webView.pageZoom + 0.1) }
    func zoomOut()   { setZoom(webView.pageZoom - 0.1) }
    func zoomReset() { setZoom(1.0) }
    private func setZoom(_ value: CGFloat) {
        webView.pageZoom = min(max(value, 0.5), 3.0)
    }
}

// MARK: - ページ内メディア状態の受け取り

extension Tab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let boolBody = (message.body as? Bool)
            ?? (message.body as? NSNumber)?.boolValue
            ?? false

        switch message.name {
        case Self.mediaStateMessageHandlerName:
            guard boolBody != self.isPlayingAudio else { return }
            self.isPlayingAudio = boolBody
        case Self.fullscreenMessageHandlerName:
            setVideoFullscreen(boolBody)
        default:
            break
        }
    }
}

// MARK: - ナビゲーションの判断役（⌘クリックを新規タブへ回す）

extension Tab: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // リンクを踏んだ操作で、⌘が押されているか
        let isLinkClick = action.navigationType == .linkActivated
        let commandHeld = action.modifierFlags.contains(.command)
        let url = action.request.url?.absoluteString

        if isLinkClick, commandHeld, let url {
            // このタブでは開かず、新規タブへ回す
            decisionHandler(.cancel)
            Task { @MainActor in self.openInNewTab?(url) }
            return
        }
        decisionHandler(.allow)
    }

    // ブラウザが表示できない応答（PDF以外のファイルなど）はダウンロードに回す
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor response: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    // ナビゲーションがダウンロードに化けた場合
    nonisolated func webView(_ webView: WKWebView,
                             navigationAction: WKNavigationAction,
                             didBecome download: WKDownload) {
        Task { @MainActor in download.delegate = self }
    }

    nonisolated func webView(_ webView: WKWebView,
                             navigationResponse: WKNavigationResponse,
                             didBecome download: WKDownload) {
        Task { @MainActor in download.delegate = self }
    }

    // WebContent プロセスが落ちたとき（WebKit 内部のクラッシュ）の立て直し。
    // 放っておくとタブが白紙のままになるので、自動で読み直す
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            print("Tab: WebContent process crashed, reloading")
            webView.reload()
        }
    }
}

// MARK: - ダウンロードの受け取り

extension Tab: WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload,
                             decideDestinationUsing response: URLResponse,
                             suggestedFilename: String,
                             completionHandler: @escaping (URL?) -> Void) {
        Task { @MainActor in
            // 保存パネルを出して、保存先はユーザーに決めてもらう
            let panel = NSSavePanel()
            // Twitter の画像 URL（…?format=jpg&name=large）のように拡張子が落ちる場合は
            // 応答の MIME タイプから補う
            var filename = suggestedFilename
            if (filename as NSString).pathExtension.isEmpty,
               let mime = response.mimeType,
               let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
                filename += "." + ext
            }
            panel.nameFieldStringValue = filename
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory,
                                                          in: .userDomainMask).first

            let result = await panel.begin()
            guard result == .OK, let url = panel.url else {
                completionHandler(nil)   // キャンセル
                return
            }
            // 同名ファイルがあれば退かす（WebKit は上書きしてくれない）
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    nonisolated func download(_ download: WKDownload,
                             didFailWithError error: Error,
                             resumeData: Data?) {
        Task { @MainActor in
            print("Download failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - UI の窓口役（target="_blank" などの新規ウィンドウ要求をタブで受ける）

extension Tab: WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString {
            Task { @MainActor in self.openInNewTab?(url) }
        }
        return nil   // 新しいウィンドウは作らず、タブで開く
    }

    // macOS ではこれを自分で実装しないと、ファイル選択パネルが出ない
    // （iOS は自動だが、Mac はアプリ側の責任）
    nonisolated func webView(_ webView: WKWebView,
                             runOpenPanelWith parameters: WKOpenPanelParameters,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping ([URL]?) -> Void) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection

            let result = await panel.begin()
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // カメラ・マイクの使用要求。これを実装しないと WebKit は getUserMedia() を
    // 無条件で拒否する（ページ側には NotAllowedError しか届かず、原因が見えない）。
    // 判断とサイトごとの記憶は MediaPermissionStore に任せる
    nonisolated func webView(_ webView: WKWebView,
                             requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                             initiatedByFrame frame: WKFrameInfo,
                             type: WKMediaCaptureType,
                             decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // WKSecurityOrigin は持ち回さず、ここで必要な文字列だけ抜いておく
        let originKey = MediaPermissionStore.storageOrigin(origin)
        let host = origin.host
        Task { @MainActor in
            let decision = await MediaPermissionStore.shared.decide(
                origin: originKey,
                host: host,
                type: type,
                in: webView.window
            )
            decisionHandler(decision)
        }
    }
}

// MARK: - タブ全体を束ねる管理役

@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?

    // タブの自動グループ化（Apple Intelligence）。
    // 使えない環境では何もせず、従来のフラット表示のまま動く
    let grouper = TabGrouper()
    // 各タブのタイトル確定を見張る購読（タブIDごと）
    private var titleWatchers: [UUID: AnyCancellable] = [:]
    // 疑似大画面の出入りで ContentView（サイドバーの表示）を更新させる購読
    private var fullscreenWatchers: [UUID: AnyCancellable] = [:]

    // 閉じたタブの復元用スタック（URL。空文字はロビー）
    private var recentlyClosed: [String] = []

    init() { addTab() }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID }
    }

    func addTab(url: String? = nil) {
        let tab = makeTab(url: url)
        tabs.append(tab)
        selectedID = tab.id
    }

    // ⌘クリック用：裏で開いて、今のタブに留まる
    func addTabInBackground(url: String) {
        let tab = makeTab(url: url)
        tabs.append(tab)
    }

    private func makeTab(url: String?) -> Tab {
        let tab = Tab(url: url)
        // ⌘クリックされたら、この管理人に連絡が来るようにする
        tab.openInNewTab = { [weak self] link in
            self?.addTabInBackground(url: link)
        }
        // タイトルが確定・変化したらグループを組み直す。
        // デバウンスは grouper 側が持つので、ここは遠慮なく呼ぶ
        titleWatchers[tab.id] = tab.$pageTitle
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.grouper.scheduleRegroup(for: self.tabs)
            }
        // Tab の @Published は Tab を監視する View しか起こさないので、
        // サイドバー（manager を監視）のためにここで中継する
        fullscreenWatchers[tab.id] = tab.$isVideoFullscreen
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        return tab
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // 復元用に、閉じるタブの URL を控える（ロビーなら空文字）。控えは最大20件
        let restoreURL = tab.isHome ? "" : (tab.webView.url?.absoluteString ?? tab.urlText)
        recentlyClosed.append(restoreURL)
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        // 動画・音声の再生を確実に止めてから退去させる
        // （配列から外すだけだと WebView がしばらく生き残り、音だけ鳴り続ける）
        tab.webView.stopLoading()
        tab.webView.load(URLRequest(url: URL(string: "about:blank")!))
        tabs.remove(at: idx)
        // 監視とグループ割り当てを片付け、残りのタブで組み直す
        titleWatchers[tab.id] = nil
        fullscreenWatchers[tab.id] = nil
        grouper.forget(tab.id)
        grouper.scheduleRegroup(for: tabs)
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

    // ドラッグでの並べ替え：draggedID のタブを target の前または後ろに挿す。
    // グループ表示中は、落とした先のタブと同じグループへ入れる（手動扱い）
    func moveTab(draggedID: String, target: Tab, after: Bool) {
        guard draggedID != target.id.uuidString,
              let from = tabs.firstIndex(where: { $0.id.uuidString == draggedID })
        else { return }
        let moved = tabs.remove(at: from)
        if let base = tabs.firstIndex(where: { $0.id == target.id }) {
            tabs.insert(moved, at: after ? base + 1 : base)
        } else {
            tabs.append(moved)
        }
        // グループが一つも無い（従来表示）なら並び順だけ変える
        if !grouper.assignments.isEmpty {
            grouper.assignManually(moved.id, to: grouper.assignments[target.id])
        }
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
    // 胴を背景色で塗り潰し、背後の飾り（サンバースト等）が透けないようにする
    var fill: Color = Deco.ink
    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(fill)
                .overlay(Triangle().stroke(color, lineWidth: 1))
                .frame(width: 3, height: 16)
            tier(18, 18)
            tier(34, 24)
            tier(52, 28)
            tier(74, 22)
        }
    }
    private func tier(_ w: CGFloat, _ h: CGFloat) -> some View {
        Rectangle().fill(fill)
            .overlay(Rectangle().stroke(color, lineWidth: 1))
            .frame(width: w, height: h)
    }
}

// MARK: - 新規タブページ（ロビー）

struct NewTabPage: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BookmarkStore

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            // ロゴ背後のサンバースト。ビルの足元から放射する淡い光。
            // 円弧は置かず線だけにして、密度を上げすぎない
            ZStack(alignment: .bottom) {
                Sunburst(rays: 9, arcRatios: [])
                    .stroke(
                        // 要（下）から先端（上）に向かって闇に溶ける
                        LinearGradient(colors: [Deco.faintGold, Deco.faintGold.opacity(0.10)],
                                       startPoint: .bottom, endPoint: .top),
                        lineWidth: 0.8
                    )
                    .frame(width: 330, height: 150)
                SkyscraperMark()
            }

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

            LobbyBottomFan()
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deco.ink)
        .overlay { LobbyFrame() }
    }
}

// MARK: - 垂直タブバー

// サイドバーのセクション一つぶん。name が nil なら「グループ無し」のまとまり
private struct TabSection: Identifiable {
    let id: String
    let name: String?
    let tabs: [Tab]
}

// グループ見出し。細い罫の間にダイヤとグループ名を挟むアール・デコ調
private struct TabGroupHeader: View {
    let name: String
    var body: some View {
        HStack(spacing: 7) {
            Rectangle().fill(Deco.faintGold).frame(height: 0.7)
            Image(systemName: "diamond.fill")
                .font(.system(size: 4))
                .foregroundColor(Deco.dimGold)
            Text(name)
                .font(.system(size: 10, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.dimGold)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "diamond.fill")
                .font(.system(size: 4))
                .foregroundColor(Deco.dimGold)
            Rectangle().fill(Deco.faintGold).frame(height: 0.7)
        }
        .padding(.top, 8)
        .padding(.horizontal, 6)
    }
}

struct VerticalTabStrip: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var grouper: TabGrouper

    // タブの挿入位置を示す金の横バー（ブックマークと同じ人感センサー方式）
    @StateObject private var dropModel = DropIndicatorModel()

    // グループ見出し付きのセクション一覧を組み立てる。
    // tabs 配列の並び順は変えず、グループは初出順、
    // どこにも属さないタブは末尾に見出し無しでまとめる。
    // 割り当てが空（Apple Intelligence 無効・タブが少ない）なら
    // セクションは一つだけになり、従来と全く同じ見た目になる
    private var sections: [TabSection] {
        var grouped: [(name: String, tabs: [Tab])] = []
        var ungrouped: [Tab] = []
        for tab in manager.tabs {
            if let name = grouper.assignments[tab.id] {
                if let idx = grouped.firstIndex(where: { $0.name == name }) {
                    grouped[idx].tabs.append(tab)
                } else {
                    grouped.append((name, [tab]))
                }
            } else {
                ungrouped.append(tab)
            }
        }
        var result = grouped.map { TabSection(id: "group:" + $0.name, name: $0.name, tabs: $0.tabs) }
        if !ungrouped.isEmpty {
            result.append(TabSection(id: "__ungrouped__", name: nil, tabs: ungrouped))
        }
        return result
    }

    // コンテキストメニュー用：現在あるグループ名の一覧（初出順）
    private var groupNames: [String] {
        sections.compactMap { $0.name }
    }

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

            // ロゴ下の扇の飾り罫（二段の鱗紋。下に向かって闇に沈む）
            // 横の重なりは浅く（肩が触れる程度）、絞った腿が隠れないようにする
            FanFrieze(fans: 5, rays: 6, overlap: 0.5, tiers: 2)
                .stroke(
                    LinearGradient(
                        colors: [Deco.gold, Deco.gold.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
                .frame(height: 34)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(sections) { section in
                        if let name = section.name {
                            TabGroupHeader(name: name)
                        } else if sections.count > 1 {
                            // グループ無しのまとまりとの区切り（見出しは無し）
                            Rectangle().fill(Deco.faintGold)
                                .frame(height: 0.7)
                                .padding(.top, 8)
                                .padding(.horizontal, 6)
                        }
                        ForEach(section.tabs) { tab in
                            DraggableTabRow(
                                manager: manager,
                                grouper: grouper,
                                indicatorModel: dropModel,
                                tab: tab,
                                groupNames: groupNames
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            // サイドバー下端のジグザグ罫（New Tab ボタンの仕切り）
            Zigzag(teeth: 14)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            HStack(spacing: 0) {
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

                Spacer(minLength: 0)

                // タブグループの再生成ボタン。
                // Apple Intelligence が使えない環境では出さない。
                // ⌥＋クリックで手動割り当てもご破算にして組み直す
                if grouper.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Deco.gold)
                        .padding(.trailing, 16)
                } else if grouper.isAvailable {
                    Button {
                        let reset = NSEvent.modifierFlags.contains(.option)
                        grouper.regroupNow(tabs: manager.tabs, clearingManual: reset)
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundColor(Deco.gold)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Regroup Tabs (⌥-click: reset manual grouping)")
                    .padding(.trailing, 12)
                }
            }
        }
        .frame(width: 200)
        .background(Deco.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Deco.gold).frame(width: 2)
        }
    }
}

// タブ一行にドラッグ＆ドロップを着せる包み。
// 上半分に落とせば前、下半分なら後ろに挿さる（ブックマークの左右判定の縦版）
private struct DraggableTabRow: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var grouper: TabGrouper
    @ObservedObject var indicatorModel: DropIndicatorModel
    let tab: Tab
    let groupNames: [String]

    @State private var rowHeight: CGFloat = 1

    private var showBefore: Bool { indicatorModel.indicator == DropIndicator(id: tab.id, side: .before) }
    private var showAfter:  Bool { indicatorModel.indicator == DropIndicator(id: tab.id, side: .after) }

    var body: some View {
        DecoTabRow(
            tab: tab,
            grouper: grouper,
            groupNames: groupNames,
            isSelected: tab.id == manager.selectedID,
            onSelect: { manager.select(tab) },
            onClose:  { manager.closeTab(tab) }
        )
        // 高さを測っておく（上下判定に使う）
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in rowHeight = h }
            }
        )
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            tab: tab, manager: manager, height: rowHeight, indicatorModel: indicatorModel
        ))
        .overlay(alignment: .top) {
            if showBefore {
                Rectangle().fill(Deco.gold).frame(height: 2)
                    .offset(y: -1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showAfter {
                Rectangle().fill(Deco.gold).frame(height: 2)
                    .offset(y: 1).allowsHitTesting(false)
            }
        }
    }
}

// 各タブ行のドロップ（上半分＝前、下半分＝後ろ）
private struct TabDropDelegate: DropDelegate {
    let tab: Tab
    let manager: TabManager
    let height: CGFloat
    let indicatorModel: DropIndicatorModel

    private func side(_ info: DropInfo) -> DropSide {
        info.location.y < height / 2 ? .before : .after
    }

    func dropEntered(info: DropInfo) {
        indicatorModel.show(DropIndicator(id: tab.id, side: side(info)))
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicatorModel.show(DropIndicator(id: tab.id, side: side(info)))
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        let after = side(info) == .after
        indicatorModel.clear()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let idString = obj as? String else { return }
            Task { @MainActor in
                manager.moveTab(draggedID: idString, target: tab, after: after)
            }
        }
        return true
    }
}

struct DecoTabRow: View {
    @ObservedObject var tab: Tab
    @ObservedObject var grouper: TabGrouper
    let groupNames: [String]
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    private let shape = Hexagon(inset: 9)

    var body: some View {
        HStack(spacing: 6) {
            // 音を鳴らしている／ミュート中のインジケータ
            if tab.isMuted || tab.isPlayingAudio {
                Button {
                    tab.toggleMute()
                } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .foregroundColor(tab.isMuted ? Deco.faintGold : Deco.gold)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")
            }

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
                        // 見た目は小さな×のまま、押せる範囲だけを 20×20 に広げる
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
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
        .contextMenu {
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
            Menu("Move to Group") {
                ForEach(groupNames, id: \.self) { name in
                    Button {
                        grouper.assignManually(tab.id, to: name)
                    } label: {
                        if grouper.assignments[tab.id] == name {
                            Label { Text(verbatim: name) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: name)
                        }
                    }
                }
                if !groupNames.isEmpty { Divider() }
                Button("New Group…") { showingNewGroup = true }
                Button("No Group") { grouper.assignManually(tab.id, to: nil) }
            }
        }
        .alert("New Group", isPresented: $showingNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                grouper.assignManually(tab.id, to: newGroupName)
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
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
    @ObservedObject var manager: TabManager
    @EnvironmentObject var store: BookmarkStore
    @State private var showingManager = false
    // 挿入位置の金の縦バー。信号が途切えたら自動で消える（人感センサー方式）
    @StateObject private var indicatorModel = DropIndicatorModel()

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "diamond")
                .font(.system(size: 8))
                .foregroundColor(Deco.faintGold)
                .padding(.trailing, 6)

            ForEach(store.bookmarks) { bm in
                BookmarkBarItem(bm: bm, tab: tab, manager: manager, indicatorModel: indicatorModel)
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

enum DropSide { case before, after }

// どの項目のどっち側にバーを立てるか
struct DropIndicator: Equatable {
    let id: UUID
    let side: DropSide
}

// 挿入バーの自動消灯モデル。
// 「立てろ」の信号（dropUpdated）が来続ける間は点いたまま、
// 信号が途絶えたら0.25秒で勝手に消える。「消せ」の信号には一切頼らない。
@MainActor
final class DropIndicatorModel: ObservableObject {
    @Published var indicator: DropIndicator? = nil
    private var generation = 0

    // バーを立てる／立て直す。呼ばれるたびに寿命が延長される
    func show(_ new: DropIndicator) {
        if indicator != new { indicator = new }
        generation += 1
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            // 寝てる間に新しい信号が来ていたら、この消灯は無効
            if self.generation == current {
                self.indicator = nil
            }
        }
    }

    // 即時消灯（ドロップ成立時など、確実に消せる場面用）
    func clear() {
        generation += 1
        indicator = nil
    }
}

// ブックマークバーの一項目（左右判定付きドラッグ＆ドロップ）
struct BookmarkBarItem: View {
    let bm: Bookmark
    @ObservedObject var tab: Tab
    @ObservedObject var manager: TabManager
    @EnvironmentObject var store: BookmarkStore
    @ObservedObject var indicatorModel: DropIndicatorModel

    @State private var itemWidth: CGFloat = 1

    private var showBefore: Bool { indicatorModel.indicator == DropIndicator(id: bm.id, side: .before) }
    private var showAfter:  Bool { indicatorModel.indicator == DropIndicator(id: bm.id, side: .after) }

    var body: some View {
        Button {
            // ⌘を押しながらなら、裏の新規タブで開く
            if NSEvent.modifierFlags.contains(.command) {
                manager.addTabInBackground(url: bm.url)
            } else {
                tab.urlText = bm.url
                tab.load()
            }
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
        // 幅を測っておく（左右判定に使う）
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { itemWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in itemWidth = w }
            }
        )
        .onDrag { NSItemProvider(object: bm.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: BookmarkDropDelegate(
            bm: bm, store: store, width: itemWidth, indicatorModel: indicatorModel
        ))
        .overlay(alignment: .leading) {
            if showBefore {
                Rectangle().fill(Deco.gold).frame(width: 2, height: 18)
                    .offset(x: -1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if showAfter {
                Rectangle().fill(Deco.gold).frame(width: 2, height: 18)
                    .offset(x: 1).allowsHitTesting(false)
            }
        }
    }
}

// 各項目のドロップ（左半分＝前、右半分＝後ろ）
struct BookmarkDropDelegate: DropDelegate {
    let bm: Bookmark
    let store: BookmarkStore
    let width: CGFloat
    let indicatorModel: DropIndicatorModel

    private func side(_ info: DropInfo) -> DropSide {
        info.location.x < width / 2 ? .before : .after
    }

    func dropEntered(info: DropInfo) {
        indicatorModel.show(DropIndicator(id: bm.id, side: side(info)))
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // カーソルが乗っている間、連続で呼ばれ続ける＝バーの寿命が延び続ける
        indicatorModel.show(DropIndicator(id: bm.id, side: side(info)))
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        let after = side(info) == .after
        indicatorModel.clear()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let idString = obj as? String else { return }
            Task { @MainActor in
                store.move(draggedID: idString, target: bm.id, after: after)
            }
        }
        return true
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

// MARK: - アドレスバー本体（AppKit 直書き）

// SwiftUI の TextField は macOS 26 で AppKit の NSTextField として階層に
// 現れず、first responder の動きも観測不能になったため、「クリックで全選択」を
// SwiftUI 側から確実に実装する手段が無い（TapGesture・イベントモニタ・
// hitTest ・リトライすべて検証済みで不成立）。
// アドレスバーだけ NSTextField に置き換えて、クリックの一部始終を自前で握る。

// フォーカスを得るクリックで全選択する NSTextField。
// mouseDown がここに届く＝フィールドエディタがまだ無い＝未編集、なので
// フォーカスを立てて全選択し、クリック自体は飲み込む
// （super に流すとカーソル配置が選択を壊す）。
// 編集中のクリックはフィールドエディタが直接受けるためここには来ない。
// レースもリトライも無い、決定論的な実装。
final class ClickSelectTextField: NSTextField {
    // 編集の開始／終了を親（SwiftUI 側）へ知らせる
    var onEditingChanged: ((Bool) -> Void)?

    // ユーザーが実際にこの欄へ関わったか。
    // AppKit は起動時に initialFirstResponder としてこの欄を「静かに」
    // フォーカスさせることがあり、その状態を「編集中」と誤認すると
    // 最初のクリックで全選択されなくなる。engaged で両者を区別する
    private var engaged = false

    override func mouseDown(with event: NSEvent) {
        // 未編集、または「静かなフォーカス」中の最初のクリック：
        // フォーカスを立てて全選択し、クリック自体は飲み込む
        // （super に流すとカーソル配置が選択を壊す）
        if currentEditor() == nil || !engaged {
            focusAndSelectAll()
            return
        }
        super.mouseDown(with: event)
    }

    // フォーカスを立てて全選択し、engaged にする（⌘L とクリックの共通処理）
    func focusAndSelectAll() {
        engaged = true
        window?.makeFirstResponder(self)
        // makeFirstResponder 直後にエディタが未設置なら selectText で強制設置
        if currentEditor() == nil { selectText(nil) }
        currentEditor()?.selectAll(nil)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onEditingChanged?(true)
            // 受け身でフォーカスが回ってきた場合（タブ切り替えで直前の
            // first responder だった WebView が隠れた等）、NSTextField 既定の
            // 全選択は解いてカーソルだけにする。
            // ユーザー操作（クリック・⌘L）は engaged が先に立っている
            if !engaged {
                currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
            }
        }
        return ok
    }

    // タブ切り替え時の仕切り直し：編集を破棄し、engaged も下ろす。
    // abortEditing は textDidEndEditing を通らないので、編集終了の通知は手動で流す
    func resetForTabSwitch() {
        let wasEditing = currentEditor() != nil
        abortEditing()
        engaged = false
        if wasEditing { onEditingChanged?(false) }
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        engaged = false
        onEditingChanged?(false)
    }
}

struct AddressField: NSViewRepresentable {
    @Binding var text: String
    // タブの印。変わったら「別のタブに移った」ので編集を仕切り直す
    let tabToken: UUID
    // ⌘L の合図。値が変わったらフォーカスして全選択する
    let focusTrigger: Int
    let onSubmit: () -> Void
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClickSelectTextField {
        let field = ClickSelectTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator

        // 見た目は SwiftUI 版と同じ：セリフ体 12pt・金文字
        let size: CGFloat = 12
        let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        let font = serif.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        field.font = font
        field.textColor = NSColor(Deco.gold)
        field.placeholderAttributedString = NSAttributedString(
            string: String(localized: "Search or enter address"),
            attributes: [.foregroundColor: NSColor(Deco.dimGold), .font: font]
        )
        field.onEditingChanged = { editing in
            DispatchQueue.main.async { context.coordinator.parent.onEditingChanged(editing) }
        }
        return field
    }

    func updateNSView(_ field: ClickSelectTextField, context: Context) {
        context.coordinator.parent = self
        // タブが切り替わった：編集を破棄して新しいタブの URL を強制反映する。
        // （編集中ガードに阻まれて前のタブの URL が残る事故を防ぐ）
        if context.coordinator.lastTabToken != tabToken {
            let isFirstUpdate = context.coordinator.lastTabToken == nil
            context.coordinator.lastTabToken = tabToken
            if !isFirstUpdate {
                field.resetForTabSwitch()
                field.stringValue = text
            }
        }
        // 編集中の打鍵を潰さないよう、編集していないときだけ外の値を反映する
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        // ⌘L：フォーカスして全選択（engaged も立つので直後のクリックはカーソル配置）
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                field.focusAndSelectAll()
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var lastFocusTrigger: Int
        var lastTabToken: UUID?

        init(_ parent: AddressField) {
            self.parent = parent
            // 初回表示で勝手にフォーカスを奪わないよう、現在値で初期化
            self.lastFocusTrigger = parent.focusTrigger
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Return で確定。それ以外のキー操作は既定に任せる
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - 選択中タブの中身

struct BrowserPane: View {
    @ObservedObject var tab: Tab
    @ObservedObject var manager: TabManager
    @EnvironmentObject var store: BookmarkStore
    @State private var addressText: String = ""
    // アドレスバーを編集中か（AddressField からの通知で更新）
    @State private var addressEditing = false

    var body: some View {
        VStack(spacing: 0) {
            // アドレスバーとブックマークバーは、疑似大画面（動画が
            // ウィンドウを占有）中は隠して、全面を Web の中身に明け渡す
            if !tab.isVideoFullscreen {
            // ── アドレスバー ──
            HStack(spacing: 10) {
                NavButton(system: "chevron.left",  disabled: !tab.canGoBack)    { tab.goBack() }
                NavButton(system: "chevron.right", disabled: !tab.canGoForward) { tab.goForward() }
                NavButton(system: "arrow.clockwise", disabled: false)           { tab.reload() }

                // アドレスバーは AppKit 直書き（AddressField）。
                // 確定は delegate の insertNewline でのみ行い、target/action は
                // 使わない（action は編集終了でも発火し、ページをクリックした
                // だけで再読み込みが走る事故の再演になるため）。
                // クリックでの全選択（Safari と同じ挙動）は AddressField 内の
                // AppKit 実装が決定論的に行う。編集終了時は打ちかけを捨てて
                // 現在の URL に戻す（Return 確定時は submitAddress が先に
                // urlText を更新しているので影響なし）
                AddressField(
                    text: $addressText,
                    tabToken: tab.id,
                    focusTrigger: tab.addressBarFocusTrigger,
                    onSubmit: submitAddress,
                    onEditingChanged: { editing in
                        addressEditing = editing
                        if !editing { addressText = tab.urlText }
                    }
                )
                .frame(maxWidth: .infinity)
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
            BookmarkBar(tab: tab, manager: manager)
            }

            // ── 中身：ロビー or Web ──
            // 全タブの WebView を常に画面に置き、選択中の一枚だけを見せる。
            // NSViewRepresentable は一度作った NSView を使い回すので、
            // 単一の WebView 枚だとタブを切り替えても最初の WebView が表示され続ける。
            // また、常時マウントにより裏タブの読み込み・タイトル更新も進む
            ZStack {
                ForEach(manager.tabs) { t in
                    WebView(webView: t.webView,
                            isInteractive: t.id == tab.id && !t.isHome)
                        .opacity(t.id == tab.id && !t.isHome ? 1 : 0)
                        .allowsHitTesting(t.id == tab.id && !t.isHome)
                }
                if tab.isHome {
                    NewTabPage(tab: tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(tab.pageTitle.isEmpty ? "Skyscraper" : tab.pageTitle)
        .onAppear {
            addressText = tab.urlText
        }
        .onChange(of: tab.id) { _, _ in
            addressText = tab.urlText
        }
        .onChange(of: tab.urlText) { _, newValue in
            if !addressEditing {
                addressText = newValue
            }
        }
        .onChange(of: tab.addressBarFocusTrigger) { _, _ in
            // フォーカスと全選択は AddressField 側が focusTrigger の変化で行う。
            // ここでは表示文字列を現在の URL に揃えるだけ
            addressText = tab.urlText
        }
    }

    private func submitAddress() {
        let targetTab = manager.selectedTab ?? tab
        targetTab.urlText = addressText
        targetTab.load()
    }
}

// MARK: - 全体

struct ContentView: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var bookmarks: BookmarkStore

    var body: some View {
        HStack(spacing: 0) {
            // 疑似大画面中はサイドバーも隠す（復帰は Esc。⌘1〜⌘9 は効く）
            if manager.selectedTab?.isVideoFullscreen != true {
                VerticalTabStrip(manager: manager, grouper: manager.grouper)
            }

            if let tab = manager.selectedTab {
                BrowserPane(tab: tab, manager: manager)
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
