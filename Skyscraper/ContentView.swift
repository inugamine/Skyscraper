//
//  ContentView.swift
//  Skyscraper
//
//  Created by inugaminé on 2026/07/11.
//

import SwiftUI
import AppKit
import WebKit
import Combine
import Security
import UniformTypeIdentifiers
import Translation

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
    // 警告に使う錆色。
    // 信号機の赤をそのまま持ち込むと盤全体の色調が壊れるので、
    // 金の隣に置いても喧嘩しないテラコッタに寄せてある。
    // 使い道は鍵の警告表示だけだ（乱発すれば意味が消える）
    static let rust      = Color(red: 0xb5/255, green: 0x6a/255, blue: 0x3c/255)
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
    // 入っているフォルダの道筋。["仕事", "参考"] なら二階層目。
    // nil なら帯の直下に置く。
    //
    // 木を組まず、平坦な配列のまま道筋だけを持たせている。
    // 階層は描く直前に BookmarkTree が組み直すので、
    // 並べ替えも重複判定も今までの仕組みがそのまま生きる。
    //
    // Optional にしてあるのは古い保存を壊さないためだ。
    // 自動生成の Codable は、非 Optional の項目の鍵が無いと
    // 既定値に落ちず keyNotFound を投げる。下の init は try? で
    // 受けているので、それをやると保存済みが丸ごと消える
    var folder: [String]? = nil
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] {
        didSet {
            save()
            sync?.scheduleUpload()
        }
    }

    // iCloud への持ち回り役。こちらが強く持ち、あちらは弱く持ち返す。
    //
    // 下の init で後回しに結んでいるのは、BookmarkSync が self を要るからだ。
    // 全ての持ち物が埋まるまで self は渡せない
    private var sync: BookmarkSync?

    // 設定画面で入り切りされた時の取次ぎ。
    // 設定側は BookmarkSync を直に見ていないので、ここを通す
    func syncSettingChanged() {
        sync?.settingChanged()
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

        let sync = BookmarkSync(store: self)
        sync.start()
        self.sync = sync
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

    // 取り込み用：既にある場所と重ならないものだけを後ろに足し、足した数を返す。
    //
    // 一件ずつ append しないのは didSet のため。あれは差し替わるたびに
    // 全件を JSON へ書き出すので、千件を一件ずつ足すと千回書き出す羽目になる。
    // 手元で組み上げてから、最後に一度だけ差し替える
    func merge(_ incoming: [Bookmark]) -> Int {
        var merged = bookmarks
        var seen = Set(merged.map { Self.dedupeKey($0.url) })
        var added = 0

        for bookmark in incoming {
            let key = Self.dedupeKey(bookmark.url)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(bookmark)
            added += 1
        }

        if added > 0 { bookmarks = merged }
        return added
    }

    // 重複を見るための均し。scheme と host の大文字小文字、末尾の /
    // の有無だけで同じ場所が二件に割れるのを防ぐ。
    // 保存する URL そのものには手を触れない（表示も遷移も書かれた通りに）
    private static func dedupeKey(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if var components = URLComponents(string: text), let host = components.host {
            components.scheme = (components.scheme ?? "https").lowercased()
            components.host = host.lowercased()
            text = components.string ?? text
        }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func remove(_ bm: Bookmark) {
        bookmarks.removeAll { $0.id == bm.id }
    }

    // 取り込みを引っ返す時の逃げ道。
    // 一件ずつ押して消すのは十件で限界だ
    func deleteAll() {
        guard !bookmarks.isEmpty else { return }
        bookmarks = []
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
                // 保存先の決定と進捗の把握は DownloadManager に任せる
                download.delegate = DownloadManager.shared
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
        container.isHidden = !isInteractive
        mount(webView, in: container)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.isInteractive = isInteractive
        // 裏タブは AppKit の層でも「隠れている」状態にする。
        //
        // opacity(0) だけだと、ビュー階層上は「窓に載ってて hidden でない」
        // ままなので、WebKit は全タブを表示中だと見なす。すると裏タブで
        // 動画が鳴っている間、WebCore が自前で
        // PreventUserIdleDisplaySleep（"HTMLMediaElement playback"）を握り続け、
        // こちらが SleepBlocker で手を放しても画面が寝ない。
        // 描画も全タブ分回り続けるので、そもそも無駄が多い。
        //
        // 隠すのは WKWebView 本体ではなくこの器の方だ。
        // 全画面再生に入ると WebKit は WKWebView を別の窓へ引っこ抜くので、
        // 本体に isHidden を立てると大画面が真っ黒になる。
        // 器なら、引っこ抜かれている間は中身と縁が切れているので影響しない。
        //
        // マウントは外さないので、戻ってきた時の再読み込みは起きない。
        // 裏タブの読み込みと題名の取得もこれまで通り進む
        container.isHidden = !isInteractive

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
    // 設定は必ず生成前に済ませる。
    //
    // let ではなく var なのは、しばらく触られていないタブを畳む時に
    // 一度捨て、戻ってきた時に作り直すためだ。
    // 差し替えるのはこのファイルの中からだけ（private(set)）
    private(set) var webView: WKWebView

    // WKWebView の器を作る。
    // popup が渡された場合は、WebKit が用意した設定をそのまま使う。
    // 自前の設定で作り直すと window.opener の関係が結ばれず、
    // 「開いた窓が親に結果を返す」流れ（OAuth など）が成立しない
    private static func makeWebView(_ popup: WKWebViewConfiguration?) -> WKWebView {
        let configuration = popup ?? WKWebViewConfiguration()
        // window.open() から渡される configuration は開いた側の複製だが、
        // userContentController だけは参照ごと共有されている（同じ実体）。
        // そのまま同じ名前のハンドラを足すと
        // "Attempt to add script message handler ... when one already exists" で落ちる。
        // かといって removeAll すると、開いた側のタブのハンドラまで巻き添えで消える。
        // 新しい実体に差し替えて、このタブ専用の注入場所を用意する。
        // processPool と websiteDataStore には触らない——
        // そこを替えるとクッキーの共有も window.opener の関係も壊れる
        if popup != nil {
            configuration.userContentController = WKUserContentController()
        }
        // 拡張機能（Web Extensions）を有効にする。
        // 管理役は全タブ・全ウィンドウで一つを共有する。
        // popup 経由で渡される configuration は開いた側の複製なので、
        // そちらには既に刺さっている——上書きしない
        if configuration.webExtensionController == nil {
            configuration.webExtensionController = WebExtensionManager.shared.controller
        }
        // 動画の全画面ボタン（Fullscreen API）を使えるようにする。
        // macOS の WKWebView はこれが既定で無効で、ページが
        // requestFullscreen() を呼んでも黙って拒否される（おかげで
        // YouTube も X も大画面ボタンが無反応になる）
        configuration.preferences.isElementFullscreenEnabled = true
        // かな漢字変換の確定 Enter がページに素通りするのを塞ぐ。
        // 詳しい事情は IMEGuard.swift に書いた。
        // popup の場合は上で userContentController を差し替えた後なので、
        // どちらの経路で来ても自分の実体に仕込まれる
        configuration.userContentController.addUserScript(IMEGuard.userScript)
        // ピクチャ・イン・ピクチャはここでは開けない。
        // iOS には allowsPictureInPictureMediaPlayback があるが、
        // macOS の WKWebViewConfiguration / WKPreferences には相当する
        // 公開項目が無い（macOS 26 SDK で確認済み）。
        // 標準の requestPictureInPicture() は呼べるが NotSupportedError を返し、
        // 素の <video controls> でさえ WebKit 純正の操作盤に PiP ボタンが出ない。
        // つまり WKWebView 自体で無効化されている。
        // 非公開の _allowsPictureInPictureMediaPlayback を KVC で突く手はあるが、
        // キー名が変われば実行時に例外で落ちるので採用しない
        return SkyscraperWebView(frame: .zero, configuration: configuration)
    }

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
    // リーダーモードが使えるページか（Readability の判定器による）
    @Published var isReaderAvailable: Bool = false
    // リーダーモード表示中か
    @Published var isReaderActive: Bool = false
    // ページ内検索バーを出しているか
    @Published var isFindBarVisible: Bool = false
    // 検索語
    @Published var findQuery: String = ""
    // 直近の検索が空振りしたか（入力欄の色を落とす合図）
    @Published var findNotFound: Bool = false
    // 検索欄に焦点を移す合図（⌘F のたびに増える）
    @Published var findFocusTrigger: Int = 0
    // ブロックしたポップアップ（知らせバーに出す）
    @Published var blockedPopups: [BlockedPopup] = []

    // 拡張機能のボタンを描き直す合図。
    // アイコンやバッジは WKWebExtension.Action が持っていて、
    // 変わったことはデリゲート（didUpdate action:）でしか分からない。
    // 値そのものを持たず、「変わった」という事実だけを数えて View を起こす
    @Published var extensionActionRevision: Int = 0

    func extensionActionsDidChange() {
        extensionActionRevision &+= 1
    }

    // 読み込みに失敗した顛末。nil なら何も起きていない
    @Published var loadError: PageError?

    // ログイン情報について今その場で訊いていること。nil なら何も出さない
    @Published var passwordPrompt: PasswordPrompt?

    // 送信されたらしい中身の控え。
    // 打った直後は「ログインが通ったか」がまだ分からないので、
    // 次の画面へ移るか入力欄が消えるまで、訊かずに手元へ置いておく
    private var passwordCandidate: PasswordCandidate?
    // 控えを抱えたまま何も起きなかった時のための番人
    private var passwordCandidateTimeout: Task<Void, Never>?
    // 問いを出している間だけ、答えを待つ中身を持つ
    fileprivate var pendingSave: PasswordCandidate?

    // 失敗した宛先。やり直しに使う。
    // WKWebView は commit していない読み込みを覚えていないので、
    // reload() を呼んでも何も起きない（＝自前で持つしかない）
    private var failedURL: URL?

    // ⌘クリックされたリンクを新規タブで開くための連絡先（TabManager が入れる）
    var openInNewTab: ((String) -> Void)?

    // window.open() で新しい器を求められた時の連絡先（TabManager が入れる）。
    // 返された WKWebView をそのまま WebKit に渡す
    var openPopup: ((WKWebViewConfiguration) -> WKWebView?)?

    // window.close() で自分を畳むための連絡先（TabManager が入れる）
    var requestClose: (() -> Void)?

    // 自分を前に出してもらうための連絡先（TabManager が入れる）。
    // 裏のタブが alert() を出した時に使う——見えていないページの問いに
    // 答えろと言われても、利用者には何のことか分からない
    var requestActivate: (() -> Void)?

    // セッション復元で作られたが、まだ中身を読みに行っていない URL。
    // 起動時に全タブを一斉に読み込むと回線も CPU も持っていかれるので、
    // 復元直後は URL と題名だけを持たせておき、実際の読み込みは
    // そのタブが選ばれた時まで先送りにする（Safari と同じ方式）
    private var pendingURL: String?

    // 先送りにしている履歴の復元（interactionState）。
    // これを WKWebView に入れた瞬間 WebKit が自分で読み込みを始めるので、
    // 遅延読み込みと併せる場合はここに控えておく
    private var pendingInteractionState: Data?

    // 畳んでいる間の拡大率の控え。器と一緒に捨てられるので手元に持つ
    private var savedZoom: CGFloat = 1.0

    // 最後に見られていた時刻。自動で畳む際の物差しに使う。
    // @Published にしないのは、これが動くたびに盤を描き直す理由が無いからだ
    private(set) var lastActiveAt = Date()

    func noteActivity() { lastActiveAt = Date() }

    // window.open() から生まれたタブか。
    // opener の縁は器を作り直すと切れるので、この手のタブは決して畳まない
    private let isPopupBorn: Bool

    // 器を作り直した回数。
    // SwiftUI 側はこれを .id に使う。WebView の器は一度組んだら
    // 中身を付け替えない作り（updateNSView が親子関係に触らない）なので、
    // 差し替えた WKWebView を映すには器ごと組み直させるしかない
    @Published private(set) var webViewGeneration: Int = 0

    // 中身を捨てて眠っているか。
    // サイドバーの色と、二重に畳まないための旗を兼ねる
    @Published private(set) var isUnloaded: Bool = false

    // パスキー（WebAuthn）の橋渡し役。実体は PasskeyManager.swift
    private let passkeyBridge = PasskeyBridge()

    // HTTP の認証チャレンジ（Basic / Digest / NTLM）の受け手。実体は HTTPAuth.swift。
    // 一度答えたら同じ場所には訊き直さないので、タブごとに一人持つ
    private let httpAuth = HTTPAuthPrompter()

    // alert() / confirm() / prompt() の受け手。実体は JSDialog.swift。
    // 「このページではもう出すな」を覚えるので、こちらもタブごとに一人持つ
    private let jsDialogs = JSDialogPresenter()

    // 差し出されたサーバ証明書の控え（ホストごと）。
    //
    // ここにあることは「通した」を意味しない。検証は WebKit に任せたままで、
    // こちらは提示された一枚を控えておくだけだ。
    // 鍵の盤で中身を見せる時と、顛末書の「危険を承知で続行」を
    // 押された時に、見せる材料が無いと話にならない。
    //
    // ページ一枚でも画像や CDN の分までチャレンジは飛んでくるので、
    // ホストを鍵にして引ける形で持つ。次の読み込みが始まったら捨てる
    private var serverTrusts: [String: SecTrust] = [:]

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

    // YouTube の動画広告を読み飛ばすスクリプト。
    // 広告は本編と同じ googlevideo.com から来るので通信では遮断できない。
    // 代わりにプレイヤーを監視し、広告中（.ad-showing）は広告動画を
    // 末尾まで早送りしてスキップボタンを押す。
    // クラス名は YouTube の改修で変わりうる（壊れたらここを直す）
    private static let youtubeAdSkipScript = WKUserScript(
        source: """
        (() => {
            const onYouTube = location.hostname === 'youtube.com'
                || location.hostname.endsWith('.youtube.com');
            if (!onYouTube || window.__skyscraperYtAdSkipInstalled) { return; }
            window.__skyscraperYtAdSkipInstalled = true;

            const skip = () => {
                const player = document.querySelector('.html5-video-player');
                if (!player || !player.classList.contains('ad-showing')) { return; }
                // 広告動画を末尾まで飛ばす（連続広告でも1本ずつ処理される）
                const video = player.querySelector('video');
                if (video && isFinite(video.duration) && video.duration > 0) {
                    video.currentTime = video.duration;
                }
                // スキップボタンが出ていれば押す（名前は世代でよく変わる）
                const btn = player.querySelector(
                    '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern'
                );
                if (btn) { btn.click(); }
            };
            setInterval(skip, 300);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    // deferLoad が真なら、URL は控えるだけで読み込まない（セッション復元用）。
    // title は復元直後のサイドバー表示に使う仮の題名
    // interactionState を渡せば、戻る／進むの履歴ごと引き継ぐ（閉じたタブの復元用）
    init(url: String? = nil,
         title: String = "",
         deferLoad: Bool = false,
         interactionState: Data? = nil,
         popupConfiguration: WKWebViewConfiguration? = nil) {
        isPopupBorn = popupConfiguration != nil
        webView = Tab.makeWebView(popupConfiguration)
        super.init()

        wire()
        start(url: url, title: title, deferLoad: deferLoad,
              interactionState: interactionState,
              isPopup: popupConfiguration != nil)
    }

    // このタブぶんの配線を全て済ませる。
    //
    // init から切り出してあるのは、タブを畳んで器を捨てた後、
    // 戻ってきた時に同じ配線をやり直す必要があるからだ。
    // 経路を二本に割ると、片方にだけ足した仕込みが必ず抜け落ちる。
    // 新しい注入も見張りも、必ずここに足すこと
    private func wire() {
        // 前の器に付けた見張りを畳む。
        // 初回は空なので素通りする（作り直しの時にだけ効く）
        observers.forEach { $0.invalidate() }
        observers.removeAll()

        // トラックパッドの2本指スワイプで戻る／進む
        webView.allowsBackForwardNavigationGestures = true
        // Safari の「開発」メニューから Web インスペクタを繋げるようにする。
        // WebKit はこれを明示的に許可しない限り外部からの接続を拒む
        webView.isInspectable = true
        // WKWebView 素の UA だと YouTube などに「古いブラウザ」と誤判定される。
        // 実機 Safari（macOS 27 / Version 27.0）の UA を名乗って回避する。
        // OS 部分の 10_15_7 は Safari 自身が凍結している値なので、これで正しい
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"
        // 広告の空枠を隠す。
        // 通信の遮断自体は拡張機能（uBOL）が受け持つので、
        // こちらは遮られた後に残る国内サイト固有の枠を掃除する。
        // 詳しい分担は AdBlocker.swift の冒頭に書いた
        AdBlocker.shared.apply(to: webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.addUserScript(Self.mediaPlaybackObserverScript)
        webView.configuration.userContentController.addUserScript(Self.youtubeAdSkipScript)
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Self.mediaStateMessageHandlerName
        )
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Self.fullscreenMessageHandlerName
        )
        // 動画の再生中はスクリーンセーバーと画面のスリープを止める。
        // 受け口はアプリ共通の一人（SleepBlocker.shared）なので、
        // タブが消えても困らない＝弱参照の包みは要らない。詳しくは SleepBlocker.swift
        webView.configuration.userContentController.addUserScript(SleepBlocker.userScript)
        webView.configuration.userContentController.add(
            SleepBlocker.shared,
            name: SleepBlocker.messageHandlerName
        )
        // パスキー：polyfill の注入と、返信付きハンドラの登録。
        // 横取り対象（navigator.credentials）はページ本来の世界に居るので .page
        passkeyBridge.webView = webView
        webView.configuration.userContentController.addUserScript(PasskeyBridge.userScript)
        webView.configuration.userContentController.addScriptMessageHandler(
            passkeyBridge,
            contentWorld: .page,
            name: PasskeyBridge.messageHandlerName
        )
        // ログイン欄の見張りと記入。
        // ページ本来の JS から覗けない専用の世界に仕込む（PasswordFill.swift）
        webView.configuration.userContentController.addUserScript(PasswordFill.userScript)
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            contentWorld: PasswordFill.world,
            name: PasswordFill.messageHandlerName
        )
        // KVO の通知は nonisolated な場（KVO が発火したスレッド）で届く。
        // [weak self] は仕組み上 `weak var self` なので、そのまま Task の中で
        // self? を触ると「並行実行のコードが var を跨いで参照している」扱いになり、
        // Swift 6 ではエラーになる。Task に入る前に let へ落としておく
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let urlText = wv.url?.absoluteString,
                      self.urlText != urlText else { return }
                self.urlText = urlText
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            Task { @MainActor in self.canGoBack = wv.canGoBack }
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            Task { @MainActor in self.canGoForward = wv.canGoForward }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isLoading = wv.isLoading
                // ページ遷移で疑似大画面の CSS ごと消えるので、アプリ側も畳む
                if wv.isLoading, self.isVideoFullscreen {
                    self.setVideoFullscreen(false)
                }
                // ページ遷移でリーダー表示も消える。状態と判定を仕切り直し、
                // 読み込み完了時に改めて判定する
                if wv.isLoading {
                    // ページを離れたらポップアップの知らせも納める
                    if !self.blockedPopups.isEmpty { self.blockedPopups.removeAll() }
                    if self.isReaderActive { self.isReaderActive = false }
                    if self.isReaderAvailable { self.isReaderAvailable = false }
                } else {
                    self.detectReaderAvailability()
                }
                // ページ遷移後もミュートを貼り直す（スクリプトはページごとに入れ直るため）
                if !wv.isLoading, self.isMuted {
                    _ = try? await wv.evaluateJavaScript("window.__skyscraperSetMuted?.(true);")
                }
            }
        })
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            Task { @MainActor in self.pageTitle = wv.title ?? "" }
        })
    }

    // 最初に何を映すかを決める。
    //
    // 配線（wire）と別にしてあるのは、畳んだタブを起こす時には
    // 配線だけをやり直し、中身は控えてある interactionState から
    // 戻すからだ。両方を一つに混ぜると分けられなくなる
    private func start(url: String?, title: String, deferLoad: Bool,
                       interactionState: Data?, isPopup: Bool) {
        if isPopup {
            // window.open() から生まれたタブ。
            // 中身を入れるのは WebKit の仕事なので、こちらからは load しない。
            // ロビーではないので isHome は下ろしておく
            isHome = false
        } else if let interactionState {
            // 履歴ごとの復元。読み込みは WebKit が始めるので load() は呼ばない
            isHome = false
            pageTitle = title
            urlText = url ?? ""
            if deferLoad {
                pendingInteractionState = interactionState
                // 器はあるが中身は無い。畳んだタブと全く同じ状態なので、旗も揃える
                isUnloaded = true
            } else {
                restore(interactionState)
            }
        } else if let url {
            urlText = url
            if deferLoad {
                // 読み込みはまだ。ロビーではないので isHome は下ろし、
                // 題名は保存しておいたものを仮に出しておく
                isHome = false
                pageTitle = title
                pendingURL = url
                isUnloaded = true
            } else {
                load()
            }
        }
    }

    // 先送りにしていた読み込みを始める（そのタブが初めて選ばれた時に呼ぶ）。
    // 読み込み済みなら何もしない
    func activateIfDeferred() {
        if let state = pendingInteractionState {
            pendingInteractionState = nil
            pendingURL = nil
            isUnloaded = false
            restore(state)
            webView.pageZoom = savedZoom
            return
        }
        guard let pending = pendingURL else { return }
        pendingURL = nil
        isUnloaded = false
        urlText = pending
        load()
        webView.pageZoom = savedZoom
    }

    // 畳んでよいタブか。
    //
    // ・ロビー（捨てる中身が無い）
    // ・window.open() 生まれ（opener の縁が切れる）
    // ・音を鳴らしている
    // ・既に畳んである、またはまだ一度も読んでいない
    //
    // 選択中かどうかはここでは見ない——タブは自分が見られているかを
    // 知らない。それは TabManager の仕事だ。
    //
    // ダウンロード進行中の扱いは未検証だ。WKDownload が器の死後も
    // 生きるなら何も要らないし、死ぬならここに一行足すことになる
    var canUnload: Bool {
        !isHome
            && !isPopupBorn
            && !isPlayingAudio
            && !isUnloaded
            && pendingURL == nil
            && pendingInteractionState == nil
    }

    // 履歴の控え。
    // 畳んでいる間は WKWebView が空なので、手元の控えを返す。
    // 閉じたタブの復元（⇧⌘T）がここを見る
    var restorableState: Data? {
        pendingInteractionState ?? webView.interactionState as? Data
    }

    // 中身を捨てて、空の器を据え直す。
    //
    // WKWebView 一枚につき WebContent プロセスが一つ立つので、
    // 実メモリを返すには器そのものを捨てるしかない
    //（about:blank を読ませてもプロセスは残る）。
    //
    // 戻る／進むの履歴とスクロール位置は interactionState に控えるが、
    // フォームの打ちかけは戻らない。ここは割り切る
    func unload() {
        guard canUnload else { return }

        pendingInteractionState = webView.interactionState as? Data
        // 控えが取れなかった場合の保険。番地だけは覚えておく
        if pendingInteractionState == nil {
            pendingURL = webView.url?.absoluteString ?? urlText
        }
        savedZoom = webView.pageZoom

        // 古い器を黙らせてから縁を切る。
        // 順番が肝だ——先に手を放すと、鳴っている音が止まらないまま
        // どこかに掴まれて生き残る余地が出る（closeTab と同じ理屈）
        let old = webView
        old.stopLoading()
        old.pauseAllMediaPlayback(completionHandler: nil)
        old.closeAllMediaPresentations {}
        old.configuration.userContentController.removeAllScriptMessageHandlers()
        old.configuration.userContentController.removeAllUserScripts()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        // これを忘れると一切の意味が無くなる。
        // WebViewContainer は addSubview で器を強く掴んでいるので、
        // ここで剥がさない限り、差し替えても古い方が画面に掴まれたまま生き残る
        old.removeFromSuperview()

        // 空の器を据えて配線し直す。
        // ここで作り直しておけば、tab.webView を見る箇所
        //（セッション保存・拡張機能・スリープ抑制）は
        // Optional を気にせず今まで通り動く
        webView = Tab.makeWebView(nil)
        wire()

        isUnloaded = true
        isLoading = false
        canGoBack = false
        canGoForward = false
        webViewGeneration &+= 1
    }

    // 控えておいた履歴（戻る／進むの連なりとスクロール位置）を流し込む。
    // interactionState は代入した時点で WebKit が読み込みを始めるので、
    // こちらから load() を重ねると同じページを履歴に積み直すことになる
    private func restore(_ state: Data) {
        webView.interactionState = state
        // 保存形式が合わない等で黙って捨てられた場合の保険。
        // 受け入れられていれば現在項目が入っている
        if webView.backForwardList.currentItem == nil, webView.url == nil {
            load()
            return
        }
        // 矢印の明滅をその場で合わせる。
        // KVO でも届くが、復元は一瞬で終わるので変化を拾い損ねる道理がある
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func load() {
        guard let url = Tab.resolveURL(from: urlText) else { return }
        isHome = false
        // file:// は load(URLRequest:) だと、同じ階層の CSS や画像すら読めない
        //（WebKit がそのファイル一枚ぶんしかサンドボックス拡張を下ろさないため）。
        // 読み取り許可を親ディレクトリまで広げて渡す loadFileURL を使う
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        webView.load(URLRequest(url: url))
    }

    // 入力をどう受け取ったか。
    // アドレスバーの候補一覧が「Return を押したら何が起きるか」を
    // 一行目に出すために、判断の結果そのものを見せる必要がある
    enum Interpretation {
        case file(URL)      // ローカルの実在するファイル
        case web(URL)       // そのまま開ける URL
        case search(String) // 検索語（均した後の文字列）
    }

    // 入力が URL か検索語かを見分ける。URL ならそのまま、そうでなければ Google 検索にする
    static func resolveURL(from input: String) -> URL? {
        switch interpret(input) {
        case .file(let url), .web(let url):
            return url
        case .search(let text):
            return Self.searchURL(for: text)
        case .none:
            return nil
        }
    }

    // 見分けの本体。resolveURL と候補一覧の両方がここだけを見るので、
    // 「一覧に出た行き先」と「実際に開く場所」は必ず一致する
    static func interpret(_ input: String) -> Interpretation? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // 絶対パス（/ か ~/ で始まる）が実在するなら file:// として開く。
        // Finder で ⌥⌘C したパスをそのまま貼れる。
        // URL(fileURLWithPath:) は空白入りのパスも正しく扱う。
        // 実在しない場合は検索語に落とすので、
        // "/r/programming" のような入力を取り違えることはない
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = (text as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return .file(URL(fileURLWithPath: path))
            }
        }

        // スキーム付きの入力。
        // ただし "localhost:8080" のようにコロンの後ろが数字だけの場合は
        // ポート番号なので、スキームとは見なさず下のホスト判定へ回す
        if let scheme = Self.schemePrefix(of: text), !Self.hasPortAfterColon(text) {
            // WKWebView が開けるスキームだけ通す。
            // mailto: や javascript: はここで検索に落とす。
            // 下のホスト判定に流すと
            // "https://mailto:test@example.com" に化け、
            // mailto:test が利用者情報、example.com がホストとして
            // 全く別のサイトを開いてしまう
            if Self.loadableSchemes.contains(scheme), let url = URL(string: text) {
                return .web(url)
            }
            return .search(text)
        }

        // 空白が無く、ドットを含む（または localhost）ならホスト名とみなす
        let looksLikeHost = !text.contains(" ")
            && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://" + text) {
            return .web(url)
        }

        // それ以外は Google 検索に流す
        return .search(text)
    }

    // WKWebView が自分で開けるスキーム。
    // mailto: や javascript: を load() に渡しても何も起きず、
    // 「Return を押したのに無反応」になるだけなので、URL 扱いしない
    private static let loadableSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob"
    ]

    // 先頭がスキームの綴り（RFC 3986：英字で始まり、英数字と + - . のみ）に
    // 合っていれば、それを小文字で返す。
    // 綴りを見るだけなので、"192.168.1.5:8080"（数字始まり）はスキームと見なされない
    private static func schemePrefix(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return nil }
        let scheme = text[text.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return nil }
        let wellFormed = scheme.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == ".")
        }
        return wellFormed ? scheme.lowercased() : nil
    }

    // コロンの直後が数字だけで、その後が末尾か / ? # なら、
    // それはスキームではなくポート番号。
    // "localhost:8080"（ホスト）と "mailto:…"（スキーム）をこれで分ける。
    // schemePrefix と同じ「最初のコロン」を見るので、両者の判断は必ず一致する
    private static func hasPortAfterColon(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let rest = text[text.index(after: colon)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        let after = rest.dropFirst(digits.count)
        return after.isEmpty || after.first == "/" || after.first == "?" || after.first == "#"
    }

    private static func searchURL(for text: String) -> URL? {
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
    }

    // ── 接続の格（アドレスバーの鍵）──

    // 今このタブが何に繋がっているか。
    // urlText から見るので、番地が変わればそのまま鍵の色に届く。
    //
    // http は相手が localhost でも .insecure のままにしてある。
    // 実害は無いが「暗号化されていない」のは事実で、
    // 鍵が場所によって別の意味になる方がたちが悪い
    var security: SiteSecurity {
        guard !isHome,
              let url = URL(string: urlText),
              let scheme = url.scheme?.lowercased()
        else { return .none }

        switch scheme {
        case "file":
            return .local
        case "https":
            guard let host = url.host(), !host.isEmpty else { return .secure }
            return CertificateExceptionStore.shared.hasException(host: host, port: url.port ?? 443)
                ? .exception
                : .secure
        case "http":
            return .insecure
        default:
            return .none
        }
    }

    // 控えてある証明書。無ければ nil（鍵の盤がその旨を出す）
    func serverTrust(for host: String) -> SecTrust? {
        serverTrusts[host]
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }

    // ── 戻る／進むの履歴（長押しメニュー用）──

    // メニューに並べる上限。深いサイトだと数十件になり、
    // 画面の端まで伸びて選べなくなる
    private static let historyMenuLimit = 15

    // どちらも「近い順」で返す（先頭が一つ前・一つ先）。
    // WKBackForwardList の backList は古い順なので、こちらで引っくり返す。
    // forwardList は元から近い順なのでそのまま
    var backHistory: [WKBackForwardListItem] {
        Array(webView.backForwardList.backList.reversed().prefix(Self.historyMenuLimit))
    }

    var forwardHistory: [WKBackForwardListItem] {
        Array(webView.backForwardList.forwardList.prefix(Self.historyMenuLimit))
    }

    // 履歴の一件へ直接飛ぶ。
    // 既に一覧から外れた項目を渡しても WKWebView が黙って無視するので、
    // メニューを開いてから選ぶまでの間にページが動いても壊れない
    func go(to item: WKBackForwardListItem) {
        webView.go(to: item)
    }

    // メニューの一行。題名が無ければ URL で代用し、長すぎるものは切る
    static func historyLabel(for item: WKBackForwardListItem) -> String {
        let title = item.title ?? ""
        let text = title.isEmpty ? item.url.absoluteString : title
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    // 顛末書が出ている間は WKWebView 側に読み込むものが無い
    //（commit まで至らなかった読み込みは覚えられていない）。
    // 控えておいた宛先へ自分で行き直す
    func reload() {
        if let failedURL {
            webView.load(URLRequest(url: failedURL))
            return
        }
        webView.reload()
    }
    // ⇧⌘R：キャッシュを一切当てにせず取り直す（画像・CSS・JS まで全部）。
    // reload() は検証（If-None-Match 等）で済ませることがあるが、
    // こちらは WebKit のキャッシュを無視してオリジンに取りに行く
    func reloadFromOrigin() {
        if let failedURL {
            webView.load(URLRequest(url: failedURL, cachePolicy: .reloadIgnoringLocalCacheData))
            return
        }
        webView.reloadFromOrigin()
    }

    // アドレスバーにフォーカスを移す合図を送る
    func focusAddressBar() { addressBarFocusTrigger += 1 }

    // ミュートの切り替え。ページ側のスクリプトが状態を記憶し、
    // 新しいメディア要素にも自動で適用する
    func toggleMute() {
        isMuted.toggle()
        webView.evaluateJavaScript("window.__skyscraperSetMuted?.(\(isMuted));")
    }

    // リーダーモードが使えるページかを判定する（読み込み完了時に呼ぶ）。
    // 判定器がバンドルに無い場合は detectJS が "false;" になり、
    // ボタンは永遠に出ない（静かに無効化）
    private func detectReaderAvailability() {
        webView.evaluateJavaScript(Reader.detectJS) { [weak self] result, error in
            if let error {
                print("Reader detect error: \(error.localizedDescription)")
            }
            let available = (result as? Bool)
                ?? (result as? NSNumber)?.boolValue
                ?? false
            Task { @MainActor in
                guard let self, self.isReaderAvailable != available else { return }
                self.isReaderAvailable = available
            }
        }
    }

    // リーダーモードの出入り。入場は本文抽出に成功したときだけ状態を立てる
    func toggleReader() {
        if isReaderActive {
            webView.evaluateJavaScript(Reader.exitJS, completionHandler: nil)
            isReaderActive = false
        } else {
            webView.evaluateJavaScript(Reader.enterJS) { [weak self] result, _ in
                let ok = (result as? Bool)
                    ?? (result as? NSNumber)?.boolValue
                    ?? false
                Task { @MainActor in
                    if ok { self?.isReaderActive = true }
                }
            }
        }
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

    // ── ページ内検索（⌘F）──

    // 検索バーを出して入力欄に焦点を移す。
    // 既に出ている場合も全選択し直す（Safari と同じ）
    func showFindBar() {
        isFindBarVisible = true
        findFocusTrigger += 1
    }

    func hideFindBar() {
        isFindBarVisible = false
        findNotFound = false
        // WebKit が付けた強調（＝選択）を解いておく
        webView.evaluateJavaScript("window.getSelection()?.removeAllRanges();",
                                   completionHandler: nil)
    }

    // ⌘G / ⇧⌘G。検索語が無ければ、まず入力欄を出す
    func findAgain(backwards: Bool) {
        guard !findQuery.isEmpty else {
            showFindBar()
            return
        }
        isFindBarVisible = true
        find(findQuery, backwards: backwards)
    }

    // WKWebView の検索は一致の有無しか返さない
    //（何件中の何件目かは取れない）ので、
    // 見つからなかった時だけ入力欄の色を落として知らせる
    func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else {
            findNotFound = false
            return
        }
        // WKFindConfiguration は Sendable ではないので、
        // Task の中で組む（外で作って渡すとキャプチャで引っ掛かる）
        Task { @MainActor [weak self] in
            guard let self else { return }
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.wraps = true
            do {
                let result = try await self.webView.find(text, configuration: configuration)
                self.findNotFound = !result.matchFound
            } catch {
                // 検索そのものが失敗した（ページが無い・破棄された等）。
                // 利用者から見れば「見つからない」と同じなので、そう見せる
                print("Find failed: \(error.localizedDescription)")
                self.findNotFound = true
            }
        }
    }

    // ── ポップアップの知らせバー ──

    // 溜めていたものを全部タブで開く
    func openBlockedPopups() {
        let urls = blockedPopups.map(\.url)
        blockedPopups.removeAll()
        for url in urls { openInNewTab?(url) }
    }

    // 今見ているページを許可一覧に加えてから開く。
    // 記録するのは「開かれる先」ではなく「開く側」のページだ
    func allowPopupsForThisSite() {
        PopupAllowList.shared.allow(PopupAllowList.originKey(for: webView.url))
        openBlockedPopups()
    }
}

// MARK: - ページ内メディア状態の受け取り

extension Tab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // ログイン欄からの知らせは辞書で届く。真偽値への変換より先に捌く
        if message.name == PasswordFill.messageHandlerName {
            handlePasswordMessage(message)
            return
        }

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

// MARK: - ログイン情報の受け渡し

extension Tab {
    // 出所はページの申告ではなく WebKit が握っている frameInfo から取る。
    // ページに名乗らせると、いくらでも他所のサイトを騙れる
    private static func origin(of message: WKScriptMessage) -> (host: String, scheme: String, port: Int)? {
        let security = message.frameInfo.securityOrigin
        let scheme = security.protocol.lowercased()
        guard !security.host.isEmpty, scheme == "https" || scheme == "http" else {
            // file:// や about: には預ける先が無い
            return nil
        }
        let port = security.port == 0 ? PasswordStore.defaultPort(for: scheme) : security.port
        return (security.host, scheme, port)
    }

    fileprivate func handlePasswordMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let origin = Self.origin(of: message)
        else { return }

        switch kind {
        case "focus":
            let rect = CGRect(x: (body["x"] as? Double) ?? 0,
                              y: (body["y"] as? Double) ?? 0,
                              width: (body["width"] as? Double) ?? 0,
                              height: (body["height"] as? Double) ?? 0)
            offerFill(for: origin, at: rect)
        case "dismiss":
            PasswordSuggestionPanel.shared.hide()
        case "submit":
            let username = (body["username"] as? String) ?? ""
            let password = (body["password"] as? String) ?? ""
            holdCandidate(host: origin.host, scheme: origin.scheme, port: origin.port,
                          username: username, password: password)
        case "gone":
            // 入力欄が消えた＝画面を移らずにログインが通った合図
            flushPasswordCandidate()
        default:
            break
        }
    }

    // MARK: 記入

    // 一件しか預かっていなくても黙って入れない。
    // 入力欄に焦点が入った時にだけ、その脇へ一覧を出す
    private func offerFill(for origin: (host: String, scheme: String, port: Int),
                           at cssRect: CGRect) {
        let logins = PasswordStore.shared.logins(host: origin.host,
                                                 scheme: origin.scheme,
                                                 port: origin.port)
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }

        guard !logins.isEmpty, let window = webView.window else {
            PasswordSuggestionPanel.shared.hide()
            return
        }

        PasswordSuggestionPanel.shared.show(logins: logins,
                                            anchoredTo: anchor(for: cssRect),
                                            in: window) { [weak self] login in
            self?.fill(login)
        }
    }

    // ページの座標（CSS ピクセル、ビューポートの左上が原点、下向き）を
    // 画面の座標（下から上）へ移す。
    //
    // 上端と下端の両方を渡す。下端だけでは、一覧を上へ返す時に
    // 欄の頭がどこにあるか分からず、欄そのものを覆ってしまう。
    // pageZoom を挟むのを忘れると、拡大しているタブで的外れな場所に出る
    private func anchor(for cssRect: CGRect) -> NSRect {
        let zoom = webView.pageZoom

        func screenPoint(fromTop distance: CGFloat, x: CGFloat) -> NSPoint {
            let viewPoint = NSPoint(
                x: x,
                y: webView.isFlipped ? distance : webView.bounds.height - distance
            )
            let windowPoint = webView.convert(viewPoint, to: nil)
            return webView.window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        }

        let left = cssRect.minX * zoom
        let top = screenPoint(fromTop: cssRect.minY * zoom, x: left)
        let bottom = screenPoint(fromTop: (cssRect.minY + cssRect.height) * zoom, x: left)

        return NSRect(x: bottom.x,
                      y: min(top.y, bottom.y),
                      width: cssRect.width * zoom,
                      height: abs(top.y - bottom.y))
    }

    func fill(_ login: SavedLogin) {
        guard let password = PasswordStore.shared.password(for: login),
              let script = PasswordFill.fillScript(username: login.username, password: password)
        else { return }
        webView.evaluateJavaScript(script, in: nil, in: PasswordFill.world) { result in
            if case .failure(let error) = result {
                print("Tab: password fill failed — \(error)")
            }
        }
    }

    // MARK: 保存を訊くまで

    private func holdCandidate(host: String, scheme: String, port: Int,
                               username: String, password: String) {
        guard !password.isEmpty, !PasswordNeverList.shared.contains(host) else { return }

        passwordCandidate = PasswordCandidate(host: host, scheme: scheme, port: port,
                                              username: username, password: password)

        // 画面も移らず入力欄も残ったまま、という作りのページもある。
        // 取りこぼさないよう、しばらく経ったら自分から訊きに行く
        passwordCandidateTimeout?.cancel()
        passwordCandidateTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.flushPasswordCandidate()
        }
    }

    // 控えを保存の問いに変える。
    // 既に同じ中身を預かっているなら何も訊かない
    fileprivate func flushPasswordCandidate() {
        passwordCandidateTimeout?.cancel()
        passwordCandidateTimeout = nil
        guard let candidate = passwordCandidate else { return }
        passwordCandidate = nil

        let store = PasswordStore.shared
        let saved = store.logins(host: candidate.host,
                                 scheme: candidate.scheme,
                                 port: candidate.port)

        if let existing = saved.first(where: { $0.username == candidate.username }) {
            guard store.password(for: existing) != candidate.password else { return }
            pendingSave = candidate
            passwordPrompt = .update(host: candidate.host, username: candidate.username)
        } else {
            pendingSave = candidate
            passwordPrompt = .save(host: candidate.host, username: candidate.username)
        }
    }

    // MARK: 問いへの返事

    func acceptPasswordPrompt() {
        guard let save = pendingSave else { return }
        PasswordStore.shared.save(host: save.host, scheme: save.scheme, port: save.port,
                                  username: save.username, password: save.password)
        dismissPasswordPrompt()
    }

    func neverSavePasswordsForThisSite() {
        if let save = pendingSave {
            PasswordNeverList.shared.add(save.host)
        }
        dismissPasswordPrompt()
    }

    func dismissPasswordPrompt() {
        pendingSave = nil
        passwordPrompt = nil
    }
}

// MARK: - ナビゲーションの判断役（⌘クリックを新規タブへ回す）

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // リンクを踏んだ操作で、⌘が押されているか
        let isLinkClick = action.navigationType == .linkActivated
        let commandHeld = action.modifierFlags.contains(.command)
        let url = action.request.url?.absoluteString

        // WKWebView が自分では開けないスキーム
        //（mailto: / tel: / zoommtg: / itms-apps: など）。
        // load しても何も起きないので、macOS の振り分けに渡す。
        //
        // リンクを踏んだ時限定なのが肝だ。これを外すと、
        // ページを開いただけで任意のローカルアプリを起動できる踏み台になる
        if isLinkClick,
           let target = action.request.url,
           let scheme = target.scheme?.lowercased(),
           !Self.loadableSchemes.contains(scheme) {
            decisionHandler(.cancel)
            Task { @MainActor in
                await ExternalSchemeStore.shared.open(target, in: webView.window)
            }
            return
        }

        if isLinkClick, commandHeld, let url {
            // このタブでは開かず、新規タブへ回す
            decisionHandler(.cancel)
            Task { @MainActor in self.openInNewTab?(url) }
            return
        }
        decisionHandler(.allow)
    }

    // ブラウザが表示できない応答（PDF以外のファイルなど）はダウンロードに回す
    func webView(_ webView: WKWebView,
                 decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.canShowMIMEType {
            decisionHandler(.allow)
            return
        }

        // 何がダウンロード判定されたのかを必ず残す（誤判の追跡用）
        let mime = response.response.mimeType ?? "(nil)"
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition") ?? "(none)"
        print("NavigationResponse not showable: url=\(response.response.url?.absoluteString ?? "?") "
              + "mime=\(mime) mainFrame=\(response.isForMainFrame) disposition=\(disposition)")

        // サブフレーム（広告・計測の iframe など）の変な応答で
        // 保存パネルを出さない。黙って握り潰す
        guard response.isForMainFrame else {
            decisionHandler(.cancel)
            return
        }

        // HTML 文書なのに「表示不可」判定の場合（Content-Disposition:
        // attachment 付きの応答などで起きる）。文書はダウンロードではなく
        // 表示に倒す（youtube.com で www.youtube.com.html の保存パネルが
        // 出る不具合の対処）
        let lowered = (response.response.mimeType ?? "").lowercased()
        if lowered == "text/html" || lowered == "application/xhtml+xml" {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.download)
    }

    // ナビゲーションがダウンロードに化けた場合
    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    // MARK: HTTP の認証要求

    // 401 と共に Basic / Digest / NTLM を求められた。
    // これを実装しない限り WebKit は資格情報を手に入れられず、
    // 白紙かサーバの素の 401 本文が残る。判断と記憶は HTTPAuth.swift に任せる
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // サーバ証明書は別の係が受ける（下の handleServerTrust）。
        // 検証そのものはあちらでも WebKit に任せたままだ
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            handleServerTrust(challenge, completionHandler: completionHandler)
            return
        }
        // クライアント証明書は WebKit の既定処理のまま。
        // 選ばせる相手（キーチェーンの識別情報）が別の話になる
        guard HTTPAuthPrompter.canHandle(challenge) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        Task { @MainActor in
            guard let answer = await httpAuth.answer(for: challenge, in: webView.window) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // 預かるのはこちらの仕事（キーチェーン）なので、
            // WebKit には今回の接続限りのものとして渡す
            completionHandler(.useCredential,
                              URLCredential(user: answer.user,
                                            password: answer.password,
                                            persistence: .forSession))
        }
    }

    // MARK: サーバ証明書

    // 差し出された証明書を、後で見せられるように控えておく係。
    //
    // ここで検証を回し直したりはしない。既定の判断は WebKit に任せたままで、
    // こちらは提示された一枚を控えるだけだ（後で見せるための材料）。
    // SecTrustEvaluateWithError をここで回すと、全ての https 接続で
    // メインスレッドが検証の往復（OCSP 等）を待つことになる。
    //
    // 例外に載っている場所だけは、控えた証明書をそのまま資格情報として返す。
    // 例外は利用者が中身を見た上で自分で作ったもので、
    // アプリを終えば消える（CertificateTrust.swift）
    private func handleServerTrust(_ challenge: URLAuthenticationChallenge,
                                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard let trust = space.serverTrust, !space.host.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        serverTrusts[space.host] = trust

        let port = space.port == 0 ? 443 : space.port
        if CertificateExceptionStore.shared.isAllowed(host: space.host,
                                                      port: port,
                                                      matching: trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: 読み込みの失敗

    // 次の読み込みが始まった／中身が届いた。前の顛末書は畳む
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        clearLoadError()
        // 出しっぱなしの一覧を連れて行かない。
        // 小窓は窓の子なので、ページが変わっても自分では消えない
        PasswordSuggestionPanel.shared.hide()
        // 断った記憶を仕切り直す（「もう一度」で訊き直せるように）
        httpAuth.noteNavigationStarted()
        // 前のページの証明書を残さない。
        // この後ちゃんとチャレンジが飛んでくるので、
        // 控えはそこで取り直される
        serverTrusts.removeAll()
        // ダイアログの抑制も前のページ限りだ。ここで解く
        jsDialogs.reset()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearLoadError()
        // 送信の後で画面が変わった。ログインが通ったとみて、
        // 控えてあった中身の保存を訊きに行く
        flushPasswordCandidate()
        // 認証を通して中身が届いた──打ったものは正しかった
        httpAuth.noteNavigationSucceeded()
    }

    // 画像や CSS だけが認証を求める作りもある。
    // その場合 didCommit は通らないので、読み終わりでも拾う
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        httpAuth.noteNavigationSucceeded()
    }

    // 相手に届く前に転んだ（名前が引けない、繋がらない、証明書で止まった等）。
    // 白紙になるのはほぼこの経路
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        report(error, on: webView)
    }

    // 中身が届き始めてから転んだ
    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        report(error, on: webView)
    }

    private func report(_ error: Error, on webView: WKWebView) {
        // 行き先が分からない場合の当て。
        // アドレスバーの文字は打ちかけの綴りかもしれないので、
        // WKWebView が握っている URL を先に見る
        let fallback = webView.url ?? Tab.resolveURL(from: urlText)
        guard let pageError = PageError.make(from: error, fallback: fallback) else {
            return
        }
        let nsError = error as NSError
        print("Tab: navigation failed url=\(pageError.url?.absoluteString ?? "?") "
              + "domain=\(nsError.domain) code=\(nsError.code) reason=\(pageError.reason)")

        failedURL = pageError.url
        loadError = pageError
        // 転んだ宛先をアドレスバーに残す。
        // WebKit は commit していない読み込みの url を握らないので、
        // 黙っていると「何を開こうとして失敗したのか」が消える
        if let url = pageError.url, urlText != url.absoluteString {
            urlText = url.absoluteString
        }
    }

    private func clearLoadError() {
        if loadError != nil { loadError = nil }
        failedURL = nil
    }

    // 顛末書に「危険を承知で続行」を出せるか。
    //
    // 証明書を控えていなければ札を出さない。
    // 見せる中身が無いのに「承知で」と言わせるのは筋が通らないし、
    // 指紋を取れなければ例外自体が作れない——
    // 押しても何も起きない札になる
    var canProceedPastCertificateError: Bool {
        guard loadError?.kind == .insecureConnection,
              let url = failedURL ?? loadError?.url,
              let host = url.host(), !host.isEmpty
        else { return false }
        return serverTrusts[host] != nil
    }

    // 顛末書の「危険を承知で続行」。
    //
    // 控えてある証明書の中身を見せ、それでも押し切られた時だけ
    // 例外に加えて開き直す。例外はその場所の、その一枚限りで、
    // アプリを終えば消える。ディスクには何も書かない
    func proceedPastCertificateError() async {
        guard let url = failedURL ?? loadError?.url,
              let host = url.host(), !host.isEmpty
        else { return }

        let port = url.port ?? 443
        let store = CertificateExceptionStore.shared
        guard await store.confirm(host: host,
                                  trust: serverTrusts[host],
                                  in: webView.window)
        else { return }

        // 指紋を取れなければ例外は作らない。
        // このまま読み直しても同じ顛末書が戻るだけなので、何もしない
        guard store.allow(host: host, port: port, trust: serverTrusts[host]) else {
            print("Tab: could not pin the certificate for \(host); exception not created")
            return
        }

        loadError = nil
        failedURL = nil
        webView.load(URLRequest(url: url))
    }

    // 顛末書の「もう一度」。控えておいた宛先へ行き直す
    func retryFailedLoad() {
        guard let failedURL else { return }
        loadError = nil
        webView.load(URLRequest(url: failedURL))
    }

    // WebContent プロセスが落ちたとき（WebKit 内部のクラッシュ）の立て直し。
    // 放っておくとタブが白紙のままになるので、自動で読み直す
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            print("Tab: WebContent process crashed, reloading")
            webView.reload()
        }
    }
}

// MARK: - UI の窓口役（target="_blank" などの新規ウィンドウ要求をタブで受ける）

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let requestedURL = navigationAction.request.url?.absoluteString

        // 利用者が「新しいタブで開け」と明示したか。
        //
        // 素直なページなら ⌘クリックは decidePolicyFor で拾えるが、
        // Bluesky のような SPA は click を自分で横取りして
        // preventDefault してから window.open() を呼ぶ。
        // すると navigationType は .linkActivated ではなく .other になり、
        // 下のポップアップ経路に落ちて前面のタブとして開いてしまう。
        //
        // navigationAction.modifierFlags も、JS 経由で呼ばれた場合は
        // 空になりうる。この判断はクリック処理の真っ最中に同期で走るので、
        // 今この瞬間の修飾キー（NSEvent）も併せて見る
        let commandHeld = navigationAction.modifierFlags.contains(.command)
            || NSEvent.modifierFlags.contains(.command)
        // WebKit の buttonNumber は DOM の流儀（0=左 1=中 2=右）
        let middleClick = navigationAction.buttonNumber == 1
        // 行き先が実在する場合に限る。
        // OAuth の窓は window.open('', 'name') で先に空の器を取り、
        // 後から location を入れる。それをここで横取りすると壊れる
        let hasTarget = !(requestedURL ?? "").isEmpty && requestedURL != "about:blank"
        let byGesture = (commandHeld || middleClick) && hasTarget

        // リンクを踏んだ結果（target="_blank"）とフォーム送信は利用者の意思。
        // 従来通り裏タブで開く
        let byLink = navigationAction.navigationType == .linkActivated
            || navigationAction.navigationType == .formSubmitted

        if byLink || byGesture {
            if let requestedURL {
                Task { @MainActor in self.openInNewTab?(requestedURL) }
            }
            return nil
        }

        // ここからは window.open()。
        // WebKit はユーザー操作を伴わない window.open を既定で弾いているので、
        // ここへ届くのは「クリックに便乗して開かれたもの」だ
        let opener = PopupAllowList.originKey(for: webView.url)
        guard PopupAllowList.shared.isAllowed(opener) else {
            if let requestedURL {
                print("Popup blocked from \(opener.isEmpty ? "(unknown origin)" : opener): \(requestedURL)")
                blockedPopups.append(BlockedPopup(url: requestedURL))
            }
            return nil
        }

        // 許可済み。WebKit が用意した configuration で器を作って返す。
        // ここで nil を返して自前でタブを開くと window.opener が繋がらず、
        // 開いた窓が親に結果を返せない（OAuth のログインが完了しない）
        return openPopup?(configuration)
    }

    // window.close() の受け皿。
    // これを実装しない限り、WKWebView は window.close() を黙って捨てる。
    // OAuth の窓は親に結果を返したあと自分で閉じにいくので、
    // 受け手が居ないと用済みの白紙タブが残り続ける
    func webViewDidClose(_ webView: WKWebView) {
        requestClose?()
    }

    // macOS ではこれを自分で実装しないと、ファイル選択パネルが出ない
    // （iOS は自動だが、Mac はアプリ側の責任）
    func webView(_ webView: WKWebView,
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
    func webView(_ webView: WKWebView,
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

    // MARK: JavaScript のダイアログ

    // この三つを実装しない限り、WebKit は alert() を何も出さず、
    // confirm() には常に false、prompt() には常に null を返す。
    // 体裁と判断は JSDialog.swift に任せ、ここでは前口上だけ整える。
    //
    // WKSecurityOrigin は持ち回さず、必要な文字列だけをここで抜く
    //（macOS 26 でメインアクター隔離になった。MediaPermission と同じ作法）。
    // 出所をページの申告ではなく frameInfo から取るのも同じ理由だ

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let host = frame.securityOrigin.host
        Task { @MainActor in
            self.requestActivate?()
            await self.jsDialogs.alert(message: message, host: host, in: webView.window)
            // 途中で抜けてはならない。呼ばない限りページの JS は止まったままだ
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let host = frame.securityOrigin.host
        Task { @MainActor in
            self.requestActivate?()
            let answer = await self.jsDialogs.confirm(message: message,
                                                      host: host,
                                                      in: webView.window)
            completionHandler(answer)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let host = frame.securityOrigin.host
        Task { @MainActor in
            self.requestActivate?()
            let answer = await self.jsDialogs.prompt(message: prompt,
                                                     defaultText: defaultText ?? "",
                                                     host: host,
                                                     in: webView.window)
            completionHandler(answer)
        }
    }

    // 離脱確認（beforeunload）。
    //
    // これだけは WKUIDelegate に公開の窓口が無い。受け口は
    // _WKUIDelegatePrivate 側にしか無く、実装しなければ WebKit は
    // 問いを飛ばして無条件に離脱を許す（書きかけの投稿が黙って消える）。
    //
    // WebKit は respondsToSelector で見てから呼ぶので、非公開の名前を
    // @objc で名乗るだけでいい（リンクはしない）。将来 WebKit が
    // この綴りを変えたら、呼ばれなくなるだけで元の振る舞いに戻る——
    // 落ちはしない。それでも非公開は非公開だ。
    // 嫌ならこの一つだけ削ればいい（上の三つは公開 API だけで成立する）
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView,
                 runBeforeUnloadConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let host = frame.securityOrigin.host
        Task { @MainActor in
            self.requestActivate?()
            let leaves = await self.jsDialogs.confirmUnload(host: host, in: webView.window)
            completionHandler(leaves)
        }
    }
}

// MARK: - タブ全体を束ねる管理役

// セッション（前回終了時のタブ構成）の保存形式
private struct SessionTab: Codable {
    var url: String     // 空文字はロビー
    var title: String   // 復元直後にサイドバーへ出す仮の題名
}

private struct SessionState: Codable {
    var tabs: [SessionTab]
    var selectedIndex: Int
}

@MainActor
final class TabManager: NSObject, ObservableObject {
    @Published var tabs: [Tab] = [] {
        didSet {
            // 拡張機能へ「タブが開いた／閉じた」を知らせる。
            // 挿入経路が六つあるので、個別に差し込まずここで差分を取る
            WebExtensionManager.shared.tabsChanged(from: oldValue, to: tabs, in: self)
            scheduleSave()
        }
    }
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            // 出しっぱなしの資格情報の一覧を、別のタブへ持ち越さない
            PasswordSuggestionPanel.shared.hide()
            // 復元されたまま眠っているタブなら、ここで初めて読みに行く
            selectedTab?.activateIfDeferred()
            // 触られた時刻を控える。去るタブも今のタブも、ここが起点になる。
            // 去る側を控えないと、選ばれた時刻のままなので
            // 一日見ていたタブが外した途端に畳まれる
            tabs.first { $0.id == oldValue }?.noteActivity()
            selectedTab?.noteActivity()
            // 拡張機能へ「見ているタブが変わった」を知らせる
            WebExtensionManager.shared.tabDidActivate(
                selectedTab,
                previous: tabs.first { $0.id == oldValue }
            )
            // スリープ抑制は「今見ているタブ」にだけ効かせる。
            // 見張り側からは誰が選ばれているか分からないので、ここから告げる。
            // 窓を閉じた時（tearDownTabs で nil になる）もここを通る
            SleepBlocker.shared.noteSelection(selectedTab?.webView, in: self)
            scheduleSave()
        }
    }

    // タブの自動グループ化（Apple Intelligence）。
    // 使えない環境では何もせず、従来のフラット表示のまま動く
    let grouper = TabGrouper()
    // 各タブのタイトル確定を見張る購読（タブIDごと）
    private var titleWatchers: [UUID: AnyCancellable] = [:]
    // 各タブの URL 変化を見張る購読（セッション保存の合図）
    private var urlWatchers: [UUID: AnyCancellable] = [:]
    // 疑似大画面の出入りで ContentView（サイドバーの表示）を更新させる購読
    private var fullscreenWatchers: [UUID: AnyCancellable] = [:]

    // 閉じたタブの控え一件ぶん。
    // interactionState には戻る／進むの履歴が丸ごと入っているので、
    // 開き直したタブでそのまま戻れる
    private struct ClosedTab {
        var url: String        // 空文字はロビー
        var title: String
        var interactionState: Data?
    }

    // 閉じたタブの復元用スタック（⇧⌘T）
    private var recentlyClosed: [ClosedTab] = []

    // ── セッションの保存 ──
    //
    // 窓ごとに一件、[SessionState] の配列で持つ。
    // v1 は単一の SessionState だったので読めない（初回だけロビーから始まる）
    private static let sessionKey = "skyscraper.session.v2"
    private static let legacySessionKey = "skyscraper.session.v1"
    // 一度に復元する窓の上限
    private static let windowLimit = 10
    // 設定の「次回起動時にタブを開き直す」。既定は有効
    static let restoreSessionKey = "skyscraper.restoreSession"
    // 一度に復元する上限。壊れた保存で限りなくタブが開くのを防ぐ
    private static let restoreLimit = 50
    // 復元が済むまでは保存しない（途中の中途半端な状態で書き潰さないため）
    private var didRestore = false
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    // ── 自動アンロード ──
    //
    // 設定の「何分触らなければ畳むか」。0 なら一切畳まない。
    // 既定を 30 分にしてあるのは、これを短くすると
    // 書きかけのフォームが黙って消える危険が増えるからだ
    static let autoUnloadKey = "skyscraper.autoUnloadMinutes"
    static var autoUnloadMinutes: Int {
        UserDefaults.standard.object(forKey: autoUnloadKey) as? Int ?? 30
    }

    // 見回りの間隔。分単位の話なので、一分に一度で事足りる
    private static let sweepInterval: TimeInterval = 60

    // メモリが足りなくなった時の見逃し幅。
    // 非常時でも、直前まで見ていたタブを落とすのは乱暴だ
    private static let pressureGrace: TimeInterval = 60

    private var idleSweeper: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

    // 生きている管理人の名簿（弱参照）。
    //
    // 以前は「最初の窓が受け持つ」形にしていたが、それだと
    // 二枚目でいくら作業しても一枚目のタブが変わらない限り保存が走らず、
    // その間の作業が一切記録されなかった。
    // 受け持ちをやめ、保存はこの名簿を回って全窓ぶんをまとめて書く
    private struct WeakManager {
        weak var manager: TabManager?
    }

    private static var registry: [WeakManager] = []

    // この窓は閉じられたか。
    //
    // 窓を閉じても SwiftUI は @StateObject を温存するので、
    // 弱参照だけでは「もう無い窓」を見分けられない。
    // 解放を待たず、閉じたことを ContentView から明示的に伝えてもらう
    private(set) var isClosed = false

    // 終了処理中か。
    // ⌘Q でも窓は畳まれるので、その onDisappear を「閉じた」と取ると
    // 全窓が除外されて何も保存されなくなる
    static var isTerminating = false

    func markOpen() {
        isClosed = false
        // 万が一 onDisappear の誤発火で片付けられていた場合の保険
        if tabs.isEmpty { addTab() }
        WebExtensionManager.shared.windowDidOpen(self)
    }

    func markClosed() {
        guard !Self.isTerminating else { return }
        isClosed = true
        idleSweeper?.cancel()
        idleSweeper = nil
        memoryPressure?.cancel()
        memoryPressure = nil
        WebExtensionManager.shared.windowDidClose(self)
        Self.saveAll()

        // まずは即座に鳴っているものを止める。
        // pauseAllMediaPlayback は WebContent プロセスへ直接「全メディア停止」を
        // 送るので、解放のタイミングに依存しない
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.pauseAllMediaPlayback(completionHandler: nil)
            tab.webView.closeAllMediaPresentations {}
        }

        // その上で、一拍おいて本当に片付ける。
        // ページが生きたままだと YouTube 側の都合で再生が戻る余地があるので、
        // closeTab と同じ水準（about:blank まで）落とす。
        // 間を置くのは、onDisappear が誤発火して直後に戻ってくる場合に
        // 中身を失わないためだ
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isClosed else { return }
            self.tearDownTabs()
        }
    }

    // 閉じた窓のタブを完全に片付ける。
    // 窓を閉じても SwiftUI は @StateObject を温存するので、
    // ここで手を下さない限り WebView は永遠に生き残る
    private func tearDownTabs() {
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.pauseAllMediaPlayback(completionHandler: nil)
            tab.webView.closeAllMediaPresentations {}
            tab.webView.load(URLRequest(url: URL(string: "about:blank")!))
            tab.webView.configuration.userContentController.removeAllScriptMessageHandlers()
            tab.webView.configuration.userContentController.removeAllUserScripts()
            grouper.forget(tab.id)
        }
        // 監視を持ったままだと購読が Tab を掴んで離さない
        titleWatchers.removeAll()
        urlWatchers.removeAll()
        fullscreenWatchers.removeAll()
        tabs.removeAll()
        selectedID = nil
    }

    // 起動時に一度だけ読む待ち行列。窓が生まれるたびに先頭を一つ取る
    private static var pendingRestores: [SessionState] = []
    private static var didLoadPending = false

    private static func takePendingRestore() -> SessionState? {
        if !didLoadPending {
            didLoadPending = true
            if let data = UserDefaults.standard.data(forKey: sessionKey),
               let states = try? JSONDecoder().decode([SessionState].self, from: data) {
                pendingRestores = Array(states.prefix(windowLimit))
            }
        }
        return pendingRestores.isEmpty ? nil : pendingRestores.removeFirst()
    }

    // まだ開くべき窓が残っているか（ContentView が次の窓を開く合図）
    static var hasPendingRestores: Bool { !pendingRestores.isEmpty }

    // 全窓ぶんをまとめて書く。どの窓で作業してもここを通る
    static func saveAll() {
        guard restoresSession else {
            forgetSavedSession()
            return
        }
        registry.removeAll { $0.manager == nil }
        let states = registry.compactMap { box -> SessionState? in
            guard let manager = box.manager, !manager.isClosed else { return nil }
            return manager.currentState()
        }
        guard !states.isEmpty,
              let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: sessionKey)
    }

    override init() {
        super.init()
        // 名簿に載る順＝窓が生まれた順。保存もこの順で並ぶ
        Self.registry.append(WeakManager(manager: self))
        restoreSession()
        didRestore = true
        startIdleSweeper()
        startMemoryPressureWatch()
        // 選択中の一枚だけは、待たずに読み込みを始める
        selectedTab?.activateIfDeferred()

        // 終了時の取りこぼしを防ぐ。デバウンス待ちの変更をここで確実に書く。
        // queue に .main を渡すと addOperation 経由の非同期配送になり、
        // 終了途中ではランループが回らずに捨てられる。
        // nil なら通知を出したスレッドで同期に走るし、
        // willTerminate は AppKit がメインスレッドから出すので assumeIsolated が成立する
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                // 終了で窓が畳まれる際の onDisappear を
                // 「閉じた」と誤解しないよう、先に旗を立ててから書く
                TabManager.isTerminating = true
                TabManager.saveAll()
            }
        }
    }

    // ── セッションの読み書き ──

    // キーが無い（初回起動）場合も復元する。切りたい人が明示的に切る
    static var restoresSession: Bool {
        UserDefaults.standard.object(forKey: restoreSessionKey) as? Bool ?? true
    }

    // 保存済みのタブ一覧をディスクから消す。
    // 設定で切られた瞬間に設定画面からも呼ぶ
    static func forgetSavedSession() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
        UserDefaults.standard.removeObject(forKey: legacySessionKey)
        pendingRestores.removeAll()
        // removeObject だけだと cfprefsd のメモリ上から消えるだけで、
        // plist への書き出しは遅延する。消したつもりのものが
        // しばらくファイルに残るのはこの設定の趣旨に反するので、
        // 削除の時だけは書き出しを待つ
        UserDefaults.standard.synchronize()
    }

    // 前回のタブ構成を読み直す。保存が無ければ真っ新なロビーを一枚だけ
    private func restoreSession() {
        // 他の窓から渡されたタブがあれば、それだけを持って始める。
        // 復元の待ち行列には手を付けない
        if let handed = Self.pendingAdoption {
            Self.pendingAdoption = nil
            adopt(handed)
            return
        }
        // 設定で切られていれば、保存済みのものも読まずに捨てる
        guard Self.restoresSession else {
            Self.forgetSavedSession()
            addTab()
            return
        }
        // 待ち行列から自分の分を一つ取る。
        // 空ならこの窓は新規（⌘N や、前回より多く開いた場合）
        guard let state = Self.takePendingRestore(), !state.tabs.isEmpty else {
            addTab()
            return
        }
        for entry in state.tabs.prefix(Self.restoreLimit) {
            // 空文字はロビー。それ以外は読み込まずに控えだけしておく
            let tab = makeTab(url: entry.url.isEmpty ? nil : entry.url,
                              title: entry.title,
                              deferLoad: true)
            tabs.append(tab)
        }
        selectedID = tabs[safe: state.selectedIndex]?.id ?? tabs.first?.id
    }

    // 保存は少し待ってからまとめて行う。SPA（X・YouTube など）は
    // スクロールのたびに URL を書き換えるので、都度書くと無駄が多い
    private func scheduleSave() {
        guard didRestore else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    private func saveSession() {
        Self.saveAll()
    }

    // この窓一枚ぶんの控え
    private func currentState() -> SessionState {
        let entries = tabs.map { tab -> SessionTab in
            var url = tab.isHome ? "" : (tab.webView.url?.absoluteString ?? tab.urlText)
            // 閉じ際に流し込む about:blank は復元しない（ロビー扱いに倒す）
            if url == "about:blank" { url = "" }
            return SessionTab(url: url, title: tab.pageTitle)
        }
        let index = tabs.firstIndex { $0.id == selectedID } ?? 0
        return SessionState(tabs: entries, selectedIndex: index)
    }

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

    // window.open() 用：WebKit が用意した設定で器を起こし、その WKWebView を返す。
    // 中身を入れるのは WebKit の仕事なので、ここでは load しない。
    // 本物のポップアップ窓に対応するので、開いたらそちらを見せる
    func addPopupTab(configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = makeTab(url: nil, popupConfiguration: configuration)
        tabs.append(tab)
        selectedID = tab.id
        return tab.webView
    }

    // ⌃Tab / ⌃⇧Tab。画面に並んでいる順で送る。端まで行ったら反対側へ回る
    func selectAdjacentTab(offset: Int) {
        let order = displayOrder
        guard order.count > 1,
              let idx = order.firstIndex(where: { $0.id == selectedID }) else { return }
        let next = ((idx + offset) % order.count + order.count) % order.count
        selectedID = order[next].id
    }

    // ── 並び順 ──

    // グループ見出し付きのセクション一覧。
    // tabs 配列の並び順は変えず、グループは初出順、
    // どこにも属さないタブは末尾に見出し無しでまとめる。
    // 割り当てが空（Apple Intelligence 無効・タブが少ない）なら
    // セクションは一つだけになり、従来と全く同じ見た目になる。
    //
    // ここに置いてあるのが肝だ。以前は VerticalTabStrip の中で組んでいたため、
    // 送り（⌃Tab）が tabs を直に歩いてしまい、グループ表示中は
    // 画面上で飛び飛びに見えていた。並び順は一箇所に集める。
    //
    // TabSection がこのファイル内の private 型なので fileprivate にする。
    // 見るのは同じファイルの VerticalTabStrip と displayOrder だけだ
    fileprivate var sections: [TabSection] {
        var grouped: [(name: String, tabs: [Tab])] = []
        var ungrouped: [Tab] = []
        for tab in tabs {
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
        var result = grouped.map {
            TabSection(id: "group:" + $0.name, name: $0.name, tabs: $0.tabs)
        }
        if !ungrouped.isEmpty {
            result.append(TabSection(id: "__ungrouped__", name: nil, tabs: ungrouped))
        }
        return result
    }

    // 画面に並んでいる順のタブ一覧（見出しを取り除いたもの）
    var displayOrder: [Tab] {
        sections.flatMap(\.tabs)
    }

    private func makeTab(url: String?,
                         title: String = "",
                         deferLoad: Bool = false,
                         interactionState: Data? = nil,
                         popupConfiguration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(url: url,
                      title: title,
                      deferLoad: deferLoad,
                      interactionState: interactionState,
                      popupConfiguration: popupConfiguration)
        wire(tab)
        return tab
    }

    // 連絡先と監視をこの管理人に繋ぐ。
    //
    // 新規に作った時も、他の窓から受け取った時も、必ずここを通す。
    // 張り替え忘れがあると、移した先で ⌘クリックやポップアップが
    // 黙って効かなくなる（古い窓に連絡が行ってしまう）
    private func wire(_ tab: Tab) {
        // ⌘クリックされたら、この管理人に連絡が来るようにする
        tab.openInNewTab = { [weak self] link in
            self?.addTabInBackground(url: link)
        }
        // window.open() で器を求められたら、ここで起こして返す
        tab.openPopup = { [weak self] configuration in
            self?.addPopupTab(configuration: configuration)
        }
        // window.close() を受けたら、そのタブを畳む
        tab.requestClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(tab)
        }
        // ダイアログを出す前に、そのタブを前へ出す。
        // 盤は窓に貼るので、裏のタブの問いをそのまま出すと
        // 全く関係の無いページの前に文句だけが垂れることになる
        tab.requestActivate = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.select(tab)
        }
        // タイトルが確定・変化したらグループを組み直す。
        // デバウンスは grouper 側が持つので、ここは遠慮なく呼ぶ
        titleWatchers[tab.id] = tab.$pageTitle
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.grouper.scheduleRegroup(for: self.tabs)
                self.scheduleSave()
            }
        // ページ遷移でもセッションを書き直す
        urlWatchers[tab.id] = tab.$urlText
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleSave() }
        // Tab の @Published は Tab を監視する View しか起こさないので、
        // サイドバー（manager を監視）のためにここで中継する
        fullscreenWatchers[tab.id] = tab.$isVideoFullscreen
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // ── 窓をまたいだ受け渡し ──

    // 他の窓へ渡すためにタブを外す。
    //
    // closeTab とは別物だ。あちらは再生を止め、about:blank を流し込み、
    // スクリプトハンドラまで外すが、移動でそれをやると中身が死ぬ。
    // WKWebView はそのまま持ち回すので、移した先で読み込み直しは起きない。
    // 閉じたタブの控え（⇧⌘T）にも積まない
    private func detach(_ tab: Tab) -> Tab? {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        tabs.remove(at: idx)
        titleWatchers[tab.id] = nil
        urlWatchers[tab.id] = nil
        fullscreenWatchers[tab.id] = nil
        grouper.forget(tab.id)
        grouper.scheduleRegroup(for: tabs)
        if selectedID == tab.id {
            selectedID = tabs[safe: idx]?.id ?? tabs.last?.id
        }
        if tabs.isEmpty { addTab() }
        return tab
    }

    // 他の窓から渡されたタブを受け取る。
    // index を渡せばその位置に挿さる（ドラッグで落とされた位置）
    func adopt(_ tab: Tab, at index: Int? = nil) {
        wire(tab)
        if let index, index >= 0, index <= tabs.count {
            tabs.insert(tab, at: index)
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
        grouper.scheduleRegroup(for: tabs)
    }

    // このタブを別の窓へ渡す。
    // 元の窓の最後の一枚だった場合は、detach の中でロビーが一枚補充される
    func moveTab(_ tab: Tab, to other: TabManager, at index: Int? = nil) {
        guard other !== self, let detached = detach(tab) else { return }
        other.adopt(detached, at: index)
    }

    // タブID から持ち主の窓を探す。
    // 窓をまたいだドラッグでは、落とされた側は相手の管理人を知らない。
    // 運ばれてくるのは UUID の文字列だけだから、ここで引き直す
    static func owner(of tabID: UUID) -> (manager: TabManager, tab: Tab)? {
        for manager in openWindows {
            if let tab = manager.tabs.first(where: { $0.id == tabID }) {
                return (manager, tab)
            }
        }
        return nil
    }

    // ドロップされたタブを受け入れる。
    //
    // 自分の窓のタブなら並べ替え、他の窓のものなら引き取る。
    // 運ばれてくるのは UUID の文字列だけなので、
    // どちらなのかはここで見分ける
    func acceptDrop(draggedID idString: String, target: Tab, after: Bool) {
        guard let id = UUID(uuidString: idString) else { return }

        // 自分の窓の中の話なら、従来通り並べ替える
        if tabs.contains(where: { $0.id == id }) {
            moveTab(draggedID: idString, target: target, after: after)
            return
        }

        // 他の窓から来た。持ち主を引いて、落とされた位置に挿す
        guard let (source, tab) = Self.owner(of: id), source !== self,
              let targetIdx = tabs.firstIndex(where: { $0.id == target.id })
        else { return }
        source.moveTab(tab, to: self, at: after ? targetIdx + 1 : targetIdx)
    }

    // サイドバーの余白に落とされた時。末尾へ回す
    func acceptDropAtEnd(draggedID idString: String) {
        guard let id = UUID(uuidString: idString) else { return }

        // 自分の窓のタブなら、末尾へ動かす
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            guard idx != tabs.count - 1 else { return }
            let tab = tabs.remove(at: idx)
            tabs.append(tab)
            grouper.scheduleRegroup(for: tabs)
            return
        }

        // 他の窓から来た。index を渡さなければ末尾に付く
        guard let (source, tab) = Self.owner(of: id), source !== self else { return }
        source.moveTab(tab, to: self)
    }

    // 開いている窓の管理人一覧（名簿順＝窓が生まれた順）。
    // 閉じた窓と、既に解放されたものは除く
    static var openWindows: [TabManager] {
        registry.compactMap { box in
            guard let manager = box.manager, !manager.isClosed else { return nil }
            return manager
        }
    }

    // 移動先の一覧に出す見出し。
    // 窓に名前が無いので、選択中のタブの題名で代用する（Safari も同じ）
    var windowLabel: String {
        let title = selectedTab?.pageTitle ?? ""
        let name = title.isEmpty ? String(localized: "New Tab") : title
        // 長い題名でメニューが横に伸び切らないようにする
        return name.count > 40 ? String(name.prefix(40)) + "…" : name
    }

    // 新しい窓へ渡すための預かり所。次に生まれる管理人が引き取る
    private static var pendingAdoption: Tab?

    // 窓を開くのは View の仕事（openWindow が環境にある）なので、
    // ここでは合図を送るだけにする
    @Published private(set) var newWindowRequests = 0

    func moveSelectedTabToNewWindow() {
        guard let tab = selectedTab else { return }
        moveTabToNewWindow(tab)
    }

    func moveTabToNewWindow(_ tab: Tab) {
        // 最後の一枚を出しても、元の窓にロビーが一枚残るだけで意味がない
        guard tabs.count > 1, let detached = detach(tab) else { return }
        Self.pendingAdoption = detached
        newWindowRequests += 1
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // 復元用に、閉じるタブを控える（ロビーなら URL は空文字）。控えは最大20件。
        //
        // 履歴（interactionState）を抜くのは、下で about:blank を流し込む前でなければ
        // ならない。後だと白紙ページまで含んだ履歴を掴むことになる
        let restoreURL = tab.isHome ? "" : (tab.webView.url?.absoluteString ?? tab.urlText)
        let restoreState = tab.isHome ? nil : tab.restorableState
        recentlyClosed.append(ClosedTab(url: restoreURL,
                                        title: tab.pageTitle,
                                        interactionState: restoreState))
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        // 動画・音声の再生を確実に止めてから退去させる。
        // about:blank の読み込みだけでは非同期で、WebView がどこかに
        // 保持されて生き残った場合に音が鳴り続ける（長時間再生した
        // YouTube で顕著）。pauseAllMediaPlayback は WebContent プロセスへ
        // 直接「全メディア停止」を送るので、解放のタイミングに依存しない
        tab.webView.stopLoading()
        tab.webView.pauseAllMediaPlayback(completionHandler: nil)
        // PiP・全画面で外に出ている再生面も畳む
        tab.webView.closeAllMediaPresentations {}
        tab.webView.load(URLRequest(url: URL(string: "about:blank")!))
        // スクリプトメッセージハンドラとユーザースクリプトを外す。
        // configuration はタブごとに独立なので、他のタブには影響しない
        tab.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        tab.webView.configuration.userContentController.removeAllUserScripts()
        tabs.remove(at: idx)
        // 監視とグループ割り当てを片付け、残りのタブで組み直す
        titleWatchers[tab.id] = nil
        urlWatchers[tab.id] = nil
        fullscreenWatchers[tab.id] = nil
        grouper.forget(tab.id)
        grouper.scheduleRegroup(for: tabs)
        if selectedID == tab.id {
            selectedID = tabs[safe: idx]?.id ?? tabs.last?.id
        }
        if tabs.isEmpty { addTab() }
    }

    func select(_ tab: Tab) { selectedID = tab.id }

    // しばらく使わないタブを畳む。
    //
    // 今は右クリックから手で呼ぶだけだ——自動化はこの後。
    // まずは手で畳んで、起こして、実メモリが返るかを目で確かめる。
    //
    // 見ているタブを畳むのは筋が通らないので、ここで弾く
    func unload(_ tab: Tab) {
        guard tab.id != selectedID, tab.canUnload else { return }
        tab.unload()
        // 器を差し替えたことを BrowserPane に伝える。
        // Tab の @Published はその Tab を見ている View しか起こさないので、
        // 一覧を持っている側へはここから告げる（fullscreenWatchers と同じ理屈）
        objectWillChange.send()
    }

    // ── 見回り ──

    // 一分に一度、放っておかれているタブを探して畳む。
    //
    // Timer ではなく Task にしてあるのは、@MainActor の中を
    // そのまま歩けるからだ。窓ごとに一人回る
    private func startIdleSweeper() {
        idleSweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sweepInterval))
                guard !Task.isCancelled else { return }
                // 窓が閉じられたら見回りも終わりだ
                guard let self, !self.isClosed else { return }
                self.sweepIdleTabs()
            }
        }
    }

    private func sweepIdleTabs() {
        let minutes = Self.autoUnloadMinutes
        guard minutes > 0 else { return }
        unloadIdleTabs(olderThan: TimeInterval(minutes) * 60)
    }

    // 指定した間触られていないタブをまとめて畳む。
    // 見ている一枚と、canUnload ではねられるタブは見送る
    @discardableResult
    private func unloadIdleTabs(olderThan idle: TimeInterval) -> Int {
        let now = Date()
        var count = 0
        for tab in tabs where tab.id != selectedID {
            guard tab.canUnload,
                  now.timeIntervalSince(tab.lastActiveAt) >= idle else { continue }
            tab.unload()
            count += 1
        }
        if count > 0 { objectWillChange.send() }
        return count
    }

    // ── メモリが足りなくなった時 ──
    //
    // 分単位の見回りを待っていては間に合わない場面がある。
    // OS が悲鳴を上げたら、その場で空けられるだけ空ける。
    //
    // 設定で「畳まない」を選んでいる人の手元では、ここも動かない。
    // 非常時だからといって、切ってある仕掛けが勝手に動く方がたちが悪い
    private func startMemoryPressureWatch() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        // ソースはこちらが強く持つので、ハンドラは必ず弱く持つこと。
        // 直に self を掴むと輪になり、窓を閉じても管理人が死なない
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                guard Self.autoUnloadMinutes > 0 else { return }
                let freed = self.unloadIdleTabs(olderThan: Self.pressureGrace)
                if freed > 0 {
                    print("TabManager: memory pressure, unloaded \(freed) tab(s)")
                }
            }
        }
        source.resume()
        memoryPressure = source
    }

    func closeSelected() {
        if let tab = selectedTab { closeTab(tab) }
    }

    // 直近に閉じたタブを開き直す。
    // 履歴の控えがあればそれを使うので、開いた直後から戻るが使える
    func reopenClosed() {
        guard let closed = recentlyClosed.popLast() else { return }
        guard !closed.url.isEmpty || closed.interactionState != nil else {
            addTab()
            return
        }
        let tab = makeTab(url: closed.url.isEmpty ? nil : closed.url,
                          title: closed.title,
                          interactionState: closed.interactionState)
        tabs.append(tab)
        selectedID = tab.id
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

    // 並び順の組み立ては TabManager に集約した。
    // 表示（ここ）と送り（⌃Tab）が同じ配列を見るので、構造的にずれない
    private var sections: [TabSection] { manager.sections }

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
            // 余白へのドロップをここで受ける。
            // 行の上なら行側が先に取るので、二重にはならない
            .onDrop(of: [.text], delegate: TabStripDropDelegate(
                manager: manager, indicatorModel: dropModel
            ))

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

    // 自分以外の窓。名簿順（窓が生まれた順）で並ぶ
    private var moveTargets: [TabMoveTarget] {
        TabManager.openWindows
            .filter { $0 !== manager }
            .map { other in
                TabMoveTarget(id: ObjectIdentifier(other), label: other.windowLabel) {
                    manager.moveTab(tab, to: other)
                }
            }
    }

    private var showBefore: Bool { indicatorModel.indicator == DropIndicator(id: tab.id, side: .before) }
    private var showAfter:  Bool { indicatorModel.indicator == DropIndicator(id: tab.id, side: .after) }

    var body: some View {
        DecoTabRow(
            tab: tab,
            grouper: grouper,
            groupNames: groupNames,
            moveTargets: moveTargets,
            isSelected: tab.id == manager.selectedID,
            onSelect: { manager.select(tab) },
            onClose:  { manager.closeTab(tab) },
            onMoveToNewWindow: { manager.moveTabToNewWindow(tab) },
            onUnload: { manager.unload(tab) }
        )
        // 高さを測っておく（上下判定に使う）。
        //
        // GeometryReader を背景に敷いて @State へ書き戻すと、
        // レイアウト計算の真っ最中に状態が変わり、SwiftUI の
        // 依存グラフが輪になる（AttributeGraph: cycle detected の山）。
        // onGeometryChange は測定結果を安全な時点で渡すための口だ
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            rowHeight = height
        }
        // タブを引っ張り出して新しい窓にする操作は入っていない。
        //
        // SwiftUI の .onDrag / .draggable には「どこにも落とされなかった」を
        // 知る手段が無い。macOS 26 SDK には DragConfiguration と
        // onDragSessionUpdated(_:) があり、DragSession.Phase.ended(DropOperation)
        // で終了を受け取れる形になっているが、
        //   .onDrag → .draggable への差し替え
        //   .dragConfiguration(DragConfiguration(allowMove: true)) の併用
        // のどちらを試しても、クロージャが一度も呼ばれなかった（2026-07 実測）。
        // dragContainer など、まだ足りない土台があると思われる。
        //
        // AppKit の NSDraggingSource まで降りれば
        // draggingSession(_:endedAt:operation:) で取れるが、
        // 行のクリック・ホバー・×ボタン・右クリックと同居させる必要があり割に合わない。
        //
        // 代わりに、右クリック →「ウィンドウへ移動」→「新しいウィンドウ」で同じことができる。
        .draggable(tab.id.uuidString)
        .dragConfiguration(DragConfiguration(allowMove: true))
        // 終了の受け口だけは残してある。
        // 今は一度も呼ばれないが、SDK 側が揃えばここに
        // .ended が届くようになる——その日の足場だ
        .onDragSessionUpdated { session in
            if case .ended = session.phase {
                // 窓の外へ落とした場合の処理（未実装）
            }
        }
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
                manager.acceptDrop(draggedID: idString, target: tab, after: after)
            }
        }
        return true
    }
}

// サイドバーの余白へのドロップ。
// 行の上に落とした時は行側の drop が先に取るので、
// ここへ来るのは「どの行の上でもない」時だけだ
private struct TabStripDropDelegate: DropDelegate {
    let manager: TabManager
    let indicatorModel: DropIndicatorModel

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        indicatorModel.clear()
    }

    func performDrop(info: DropInfo) -> Bool {
        indicatorModel.clear()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let idString = obj as? String else { return }
            Task { @MainActor in
                manager.acceptDropAtEnd(draggedID: idString)
            }
        }
        return true
    }
}

// 右クリックの「ウィンドウへ移動」に並べる一件。
// DecoTabRow は管理人も窓も知らずに済むよう、見出しと動作だけを受け取る
//（onSelect / onClose と同じ流儀）
struct TabMoveTarget: Identifiable {
    let id: ObjectIdentifier
    let label: String
    let move: () -> Void
}

struct DecoTabRow: View {
    @ObservedObject var tab: Tab
    @ObservedObject var grouper: TabGrouper
    let groupNames: [String]
    let moveTargets: [TabMoveTarget]
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMoveToNewWindow: () -> Void
    // 診断用：このタブを手で畳む
    let onUnload: () -> Void

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
                // 畳んでいる間は一段沈める。
                // 選べないわけではない（押せば起きる）ので、消したりはしない
                .foregroundColor(tab.isUnloaded
                                 ? Deco.faintGold
                                 : (isSelected ? Deco.cream : Deco.dimGold))
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
            Button("Unload Tab") { onUnload() }
                .disabled(!tab.canUnload)
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
            Menu("Move to Window") {
                Button("New Window") { onMoveToNewWindow() }
                if !moveTargets.isEmpty { Divider() }
                ForEach(moveTargets) { target in
                    Button { target.move() } label: { Text(verbatim: target.label) }
                }
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

// 押しっぱなしで履歴のメニューを出すボタン（戻る／進む）。
//
// SwiftUI だけでは組めない。Button に長押しのジェスチャを重ねると、
// 指を離した拍子に本来の動作（戻る）も一緒に走るし、
// Menu は押した瞬間に開いてしまって「短く押せば戻る」が成立しない。
// 押してから離すまでの一部始終を自分で握るために AppKit まで降りる——
// アドレスバー（AddressField）と同じ判断だ。
//
// 見た目は NavButton に合わせてある（13pt の記号・金・24×24）。
// 並べて置いても差は出ない
final class HoldNavButtonView: NSView {
    // 短く押した時の動作（戻る／進む）
    var onClick: @MainActor () -> Void = {}
    // メニューを開く直前に呼ぶ。その場の履歴を並べてもらう
    var titles: @MainActor () -> [String] = { [] }
    // 何番目を選んだか
    var onSelect: @MainActor (Int) -> Void = { _ in }

    var isDisabled = false {
        didSet { imageView.contentTintColor = tint }
    }

    // 「押しっぱなし」と見なすまでの間（秒）
    private let holdDelay: TimeInterval = 0.35

    private let imageView = NSImageView()
    private var holdTimer: Timer?
    // この押下はメニューが食った（離しても戻らない）
    private var consumed = false

    init(symbol: String) {
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = tint
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // メニューを下へ垂らすので、原点を左上に揃えておく
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    // 窓が手前に無い時の一発目も拾う（道具帯のボタンはそうあるべきだ）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tint: NSColor {
        NSColor(isDisabled ? Deco.faintGold : Deco.gold)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDisabled else { return }
        consumed = false
        holdTimer?.invalidate()
        // モードに .common を使う。既定の .default だけだと、
        // 追跡中（eventTracking）に入った途端に時計が止まる
        let timer = Timer(timeInterval: holdDelay,
                          target: self,
                          selector: #selector(holdFired),
                          userInfo: nil,
                          repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard !isDisabled, !consumed else { return }
        // 押した後で外へ逃げて離した場合は何もしない（AppKit の作法）
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    // 右クリックでも同じメニューを出す（Safari と同じ）
    override func rightMouseDown(with event: NSEvent) {
        guard !isDisabled else { return }
        showMenu()
    }

    @objc private func holdFired() {
        holdTimer = nil
        consumed = true
        showMenu()
    }

    private func showMenu() {
        let entries = titles()
        guard !entries.isEmpty else { return }

        let menu = NSMenu()
        // 盤全体の体裁に揃えてセリフ体にする
        let size: CGFloat = 12
        let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        menu.font = serif.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        for (index, title) in entries.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        // 押したまま開くので、そのまま下へ滑らせて離せば選べる。
        // すぐ離しても AppKit がメニューを留めてくれる
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        onSelect(sender.tag)
    }
}

struct HoldNavButton: NSViewRepresentable {
    let system: String
    let disabled: Bool
    let action: @MainActor () -> Void
    let titles: @MainActor () -> [String]
    let onSelect: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> HoldNavButtonView {
        let view = HoldNavButtonView(symbol: system)
        apply(to: view)
        return view
    }

    // クロージャは body の評価のたびに作り直される。
    // 古いものを握ったままだと、切り替えた後のタブの履歴を見に行けない
    func updateNSView(_ view: HoldNavButtonView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: HoldNavButtonView) {
        view.onClick = action
        view.titles = titles
        view.onSelect = onSelect
        view.isDisabled = disabled
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

            strip

            if entries.count > Self.overflowThreshold {
                allBookmarksMenu
            }

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

    // この件数を越えたら、全件を引けるメニューも出す。
    // 数えるのは帯に立つ数（フォルダは中身が何件でも一つ）だ
    private static let overflowThreshold = 8

    // 描く直前に階層へ組み直す。
    // 保存されているのは今まで通り平坦な一列だ
    private var entries: [BookmarkEntry] {
        BookmarkTree.build(store.bookmarks)
    }

    // 帯の中身。横に溢れさせない。
    //
    // 素の HStack は、中身が求める幅をそのまま親へ差し出す。
    // ブックマークが八十件もあれば「この帯には数千ポイント要る」と
    // 申告し、それが BrowserPane → ウィンドウまで押し上げられる。
    // 結果、縦タブの帯は幅ゼロまで潰され、帯自体も画面の外へ出る
    //（件数を増やした途端に盤全体が崩れるのはこれが原因だ）。
    // ScrollView は差し出された幅を素直に受けるので、何件あっても崩れない。
    //
    // fixedSize で縦だけを固めるのは、横スクロールの器が
    // 縦にも伸びて Web の中身を食うのを止めるため
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(entries) { entry in
                    switch entry {
                    case .item(let bm):
                        // 並べ替えのドラッグは平の一件だけが受ける。
                        // フォルダごと抱えて動かすのは、道筋の付け替えが
                        // 絡むので管理シート側の仕事にしてある
                        BookmarkBarItem(bm: bm, tab: tab, manager: manager,
                                        indicatorModel: indicatorModel)
                    case .folder(let folder):
                        BookmarkFolderMenu(folder: folder, open: open)
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // 帯に収まりきらない数になったら、全件をメニューからも引けるようにする。
    // 横に引っ張って探すより、一覧から選ぶ方が早い
    private var allBookmarksMenu: some View {
        Menu {
            BookmarkMenuItems(entries: entries, open: open)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10))
                .foregroundColor(Deco.dimGold)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("All bookmarks")
    }

    // 帯の一件と同じ規則。⌘ を押しながらなら裏の新規タブで開く
    private func open(_ bm: Bookmark) {
        if NSEvent.modifierFlags.contains(.command) {
            manager.addTabInBackground(url: bm.url)
        } else {
            tab.urlText = bm.url
            tab.load()
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
    @State private var confirmingDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("Bookmarks")
                    .font(.system(size: 15, design: .serif))
                    .tracking(2)
                    .foregroundColor(Deco.cream)
                Text(verbatim: "\(store.bookmarks.count)")
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(Deco.dimGold)
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

                            // フォルダの道筋。スラッシュ区切りで階層になる
                            //（"仕事/参考"）。空にすれば帯の直下へ戻る。
                            // 同じ名前を打てばそのフォルダに入る——
                            // フォルダは実体を持たず、道筋の一致で束ねているからだ
                            TextField("Folder", text: Binding(
                                get: { (bm.folder ?? []).joined(separator: "/") },
                                set: { $bm.folder.wrappedValue = Self.folderPath(from: $0) }
                            ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .serif))
                                .foregroundColor(Deco.dimGold)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Deco.field)
                                .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 0.5))
                                .frame(width: 120)

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

                if !store.bookmarks.isEmpty {
                    Button { confirmingDeleteAll = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 11))
                            Text("Delete All").font(.system(size: 12, design: .serif)).tracking(1)
                        }
                        .foregroundColor(Deco.dimGold)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(Hexagon(inset: 7).stroke(Deco.faintGold, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 660, minHeight: 420)
        .background(Deco.ink)
        .confirmationDialog("Delete every bookmark?",
                            isPresented: $confirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The bookmark bar will be emptied. This cannot be undone.")
        }
    }

    // "仕事 / 参考" を ["仕事", "参考"] にする。
    // 前後の空白と空の段は落とすので、"/仕事//" も受ける
    private static func folderPath(from text: String) -> [String]? {
        let parts = text
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
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

    // 利用者が自分の意思でこの欄に関わっているか。
    // 受け身でフォーカスが回ってきただけの状態は「編集中」ではないので、
    // 外（タブ）からの URL 反映を止めてはいけない
    var isEngaged: Bool { engaged }

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
            if engaged {
                // ユーザー操作（クリック・⌘L）は engaged が先に立っている
                onEditingChanged?(true)
            } else {
                // 受け身でフォーカスが回ってきた場合（タブ切り替えで直前の
                // first responder だった WebView が隠れた等）。
                // NSTextField 既定の全選択は解いてカーソルだけにする。
                // ここで編集開始を名乗ると、新しいタブのアドレスバーに
                // 前のタブの URL が残りっぱなしになるので黙っている
                currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
            }
        }
        return ok
    }

    // 受け身のフォーカスのまま打ち始めた場合も、そこからは本人の編集だ。
    // 以後は外からの上書きを拒む
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        if !engaged {
            engaged = true
            onEditingChanged?(true)
        }
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
    // タブ本人が持つ URL。切り替え直後はこちらを正とする
    //（上の text は親の @State なので、切り替わった一回目は
    // まだ前のタブの URL が入っている）
    let tabURL: String
    // ⌘L の合図。値が変わったらフォーカスして全選択する
    let focusTrigger: Int
    // 「編集を切り上げろ」の合図。候補を選んで移動した後に使う。
    // 焦点を握ったままだと、打ちかけの語が欄に残って
    // 行き先と表示が食い違う
    let endEditingTrigger: Int
    let onSubmit: () -> Void
    let onEditingChanged: (Bool) -> Void
    // ↑↓ で候補を選ぶ。候補が出ていない時は false を返してもらい、
    // AppKit 既定の動き（単行の欄では何も起きない）に任せる
    let onMove: (Int) -> Bool
    // Esc。候補が出ていればそれを閉じるだけに留め、
    // 二度目で既定の「打ちかけを捨てて URL に戻す」へ落とす
    let onCancel: () -> Bool

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
        let coordinator = context.coordinator
        coordinator.parent = self
        // タブが切り替わった：編集を破棄して、新しいタブの URL を強制反映する。
        //
        // ここで text（親の @State）を映してはいけない。
        // 切り替わった一回目の body 評価の時点では、親の @State は
        // まだ前のタブの URL を持っている（更新は onChange 経由で後から届く）。
        // それを書き込むと、直後に受け身のフォーカスが回ってきた場合に
        // 「編集中は上書きしない」の規則に守られて、前のタブの URL が
        // 新しいタブに居座る。タブ本人が持つ tabURL を正とする
        if coordinator.lastTabToken != tabToken {
            let isFirstUpdate = coordinator.lastTabToken == nil
            // 去るタブの「どこまで ⌘L を消化したか」を控え、
            // 次のタブの控えを取り出す。
            // 合図の数えはタブごとなので、切り替えでは必ず値が飛ぶ。
            // そのまま比べると、切り替えそのものを ⌘L と誤解して
            // 焦点を奪い、前のタブの URL を抱えたまま編集中にしてしまう。
            // 逆に、新規タブが生まれながらに求めた焦点（⌘T など）は
            // この控えとの差として残るので、下の ⌘L 処理で叶う
            if let previous = coordinator.lastTabToken {
                coordinator.seenFocusTriggers[previous] = coordinator.lastFocusTrigger
            }
            coordinator.lastTabToken = tabToken
            coordinator.lastFocusTrigger = isFirstUpdate
                ? focusTrigger                                   // 初回表示では奪わない
                : (coordinator.seenFocusTriggers[tabToken] ?? 0)
            if !isFirstUpdate {
                field.resetForTabSwitch()
            }
            field.stringValue = tabURL
            // 親の控えも揃えておく（描画中の更新になるので次の回に回す）
            if text != tabURL {
                let newText = tabURL
                DispatchQueue.main.async { coordinator.parent.text = newText }
            }
        } else if !field.isEngaged, field.stringValue != text {
            // 本人が編集している間だけ外の値を弾く。
            // 受け身のフォーカス（currentEditor は居るが engaged ではない）で
            // 弾くと、ページ遷移やタブ切り替えの結果が映らなくなる
            field.stringValue = text
        }
        // ⌘L：フォーカスして全選択（engaged も立つので直後のクリックはカーソル配置）
        if coordinator.lastFocusTrigger != focusTrigger {
            coordinator.lastFocusTrigger = focusTrigger
            coordinator.seenFocusTriggers[tabToken] = focusTrigger
            DispatchQueue.main.async {
                field.focusAndSelectAll()
            }
        }
        // 候補を選び終えた：編集を畳む。
        // タブ切り替えと同じ仕切り直しで足りる（打ちかけを捨て、
        // engaged を下ろし、編集終了を親へ知らせる）。
        // ⌘L の合図と違ってタブごとに数える必要はない——
        // 候補一覧も欄も、窓に一つしか無いため
        if coordinator.lastEndEditingTrigger != endEditingTrigger {
            coordinator.lastEndEditingTrigger = endEditingTrigger
            DispatchQueue.main.async {
                field.resetForTabSwitch()
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var lastFocusTrigger: Int
        var lastEndEditingTrigger: Int
        var lastTabToken: UUID?
        // タブごとの「消化済みの ⌘L の数え」。
        // 欄は窓に一つしか無いので、ここでタブ別に覚えておかないと
        // 切り替えと ⌘L を見分けられない（中身は Int 一つなので、
        // 閉じたタブの分が残っても実害は無い）
        var seenFocusTriggers: [UUID: Int] = [:]

        init(_ parent: AddressField) {
            self.parent = parent
            // 初回表示で勝手にフォーカスを奪わないよう、現在値で初期化
            self.lastFocusTrigger = parent.focusTrigger
            // 同じ理由で、初回に編集を畳みに行かないよう現在値から始める
            self.lastEndEditingTrigger = parent.endEditingTrigger
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Return で確定、↑↓ で候補選び、Esc で候補を閉じる。
        // それ以外のキー操作は既定に任せる。
        //
        // かな漢字変換の最中は、この窓口自体が呼ばれない
        //（変換候補の選択と確定はフィールドエディタが先に食う）。
        // 変換中の ↑↓ で候補一覧が動く心配は要らない
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCancel()
            default:
                return false
            }
        }
    }
}

// MARK: - アドレスバーの候補一覧

// アドレスバーの真下に垂らす候補の一覧。
//
// 行の当たり判定に Button を使わないのは、押した拍子に
// first responder が欄から奪われるため。そうなると欄が編集終了を名乗り、
// 候補が消えてから押した先の処理が走る（＝何も起きない）。
// onTapGesture は焦点を動かさないので、順番の心配が要らない
struct SuggestionList: View {
    let suggestions: [AddressSuggestion]
    let selected: Int
    let onHover: (Int) -> Void
    let onChoose: (AddressSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 {
                    Rectangle()
                        .fill(Deco.faintGold.opacity(0.4))
                        .frame(height: 1)
                }
                row(index, suggestion)
            }
        }
        .background(Deco.panel2)
        .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .padding(.horizontal, 16)
    }

    private func row(_ index: Int, _ suggestion: AddressSuggestion) -> some View {
        let isSelected = index == selected
        return HStack(spacing: 10) {
            Image(systemName: suggestion.symbol)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? Deco.cream : Deco.dimGold)
                .frame(width: 16)

            Text(verbatim: suggestion.title)
                .font(.system(size: 12, design: .serif))
                .foregroundColor(isSelected ? Deco.cream : Deco.gold)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(verbatim: suggestion.detail)
                .font(.system(size: 10, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.dimGold)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? Deco.gold.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onChoose(suggestion) }
        .onHover { inside in
            if inside { onHover(index) }
        }
    }
}

// MARK: - ページ内検索バー

// 検索語の入力欄。アドレスバーと同じ ClickSelectTextField を土台にする
//（macOS 26 の SwiftUI TextField は AppKit 階層に現れず、焦点も観測できない）。
// Return で次、⇧Return で前、Esc で閉じる
struct FindField: NSViewRepresentable {
    @Binding var text: String
    // 値が変わったら焦点を移して全選択する（⌘F の合図）
    let focusTrigger: Int
    let onSubmit: (Bool) -> Void   // 真なら後方検索（⇧Return）
    let onCancel: () -> Void

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

        let size: CGFloat = 12
        let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        let font = serif.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        field.font = font
        field.textColor = NSColor(Deco.cream)
        field.placeholderAttributedString = NSAttributedString(
            string: String(localized: "Find in page"),
            attributes: [.foregroundColor: NSColor(Deco.dimGold), .font: font]
        )
        return field
    }

    func updateNSView(_ field: ClickSelectTextField, context: Context) {
        context.coordinator.parent = self
        // 編集中の打鍵を潰さないよう、編集していないときだけ外の値を反映する
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { field.focusAndSelectAll() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        var lastFocusTrigger: Int

        init(_ parent: FindField) {
            self.parent = parent
            // アドレスバーと違い、出た瞬間に焦点が欲しい。
            // 現在値と違う値で始めて、最初の updateNSView で必ず焦点合わせを走らせる
            self.lastFocusTrigger = parent.focusTrigger - 1
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // 単行の欄では ⇧Return も insertNewline に来るので、
                // 修飾キーは NSEvent から直に見る
                parent.onSubmit(NSEvent.modifierFlags.contains(.shift))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

struct FindBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Deco.gold)

            FindField(
                text: $tab.findQuery,
                focusTrigger: tab.findFocusTrigger,
                onSubmit: { backwards in tab.find(tab.findQuery, backwards: backwards) },
                onCancel: { tab.hideFindBar() }
            )
            .frame(width: 240)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Hexagon(inset: 5).fill(Deco.field))
            .overlay(Hexagon(inset: 5)
                .stroke(tab.findNotFound ? Deco.dimGold : Deco.faintGold, lineWidth: 1))

            // WKWebView は「何件中の何件目」を教えてくれないので、
            // 出せるのは見つからなかったという事実だけ
            if tab.findNotFound {
                Text("Not found")
                    .font(.system(size: 10, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.dimGold)
            }

            NavButton(system: "chevron.up", disabled: tab.findQuery.isEmpty) {
                tab.find(tab.findQuery, backwards: true)
            }
            NavButton(system: "chevron.down", disabled: tab.findQuery.isEmpty) {
                tab.find(tab.findQuery)
            }

            Spacer()

            Button { tab.hideFindBar() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(Deco.dimGold)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Deco.panel2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Deco.faintGold).frame(height: 1)
        }
        // 打つそばから探す。空にしたら知らせも消える
        .onChange(of: tab.findQuery) { _, query in
            tab.find(query)
        }
    }
}

// MARK: - ポップアップの知らせバー

// 黙って捨てると OAuth のログイン窓や決済窓が壊れた時に手がない。
// 必ず知らせて、その場で開き直せる道を残す
struct PopupNoticeBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 11))
                .foregroundColor(Deco.gold)

            Text("Pop-ups blocked: \(tab.blockedPopups.count)")
                .font(.system(size: 11, design: .serif))
                .foregroundColor(Deco.cream)

            Spacer()

            noticeButton("Open") { tab.openBlockedPopups() }
            noticeButton("Always allow on this site") { tab.allowPopupsForThisSite() }

            Button { tab.blockedPopups.removeAll() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(Deco.dimGold)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Deco.panel2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Deco.faintGold).frame(height: 1)
        }
    }

    private func noticeButton(_ title: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ログイン情報の知らせバー

// ポップアップの知らせと同じ様式。ダイアログで手を止めさせず、
// 画面の中に控えめに出して、無視して先へ進める形にする
struct PasswordNoticeBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let prompt = tab.passwordPrompt {
            HStack(spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.gold)

                switch prompt {
                case .save(let host, let username):
                    Text("Save the password for \(host)?")
                        .font(.system(size: 11, design: .serif))
                        .foregroundColor(Deco.cream)
                    account(username)
                    Spacer()
                    noticeButton("Save") { tab.acceptPasswordPrompt() }
                    noticeButton("Not Now") { tab.dismissPasswordPrompt() }
                    noticeButton("Never for This Site") { tab.neverSavePasswordsForThisSite() }

                case .update(let host, let username):
                    Text("Update the saved password for \(host)?")
                        .font(.system(size: 11, design: .serif))
                        .foregroundColor(Deco.cream)
                    account(username)
                    Spacer()
                    noticeButton("Update") { tab.acceptPasswordPrompt() }
                    noticeButton("Not Now") { tab.dismissPasswordPrompt() }
                }

                Button { tab.dismissPasswordPrompt() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(Deco.dimGold)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Deco.panel2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Deco.faintGold).frame(height: 1)
            }
        }
    }

    // 利用者名。空（名前欄の無いログイン）の時は何も出さない
    @ViewBuilder
    private func account(_ username: String) -> some View {
        if !username.isEmpty {
            Text(verbatim: username)
                .font(.system(size: 11, design: .serif))
                .foregroundColor(Deco.gold)
                .lineLimit(1)
        }
    }

    private func noticeButton(_ title: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { chip(Text(title)) }
            .buttonStyle(.plain)
    }

    private func chip(_ label: Text) -> some View {
        label
            .font(.system(size: 10, design: .serif))
            .tracking(1)
            .foregroundColor(Deco.gold)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
    }
}

// MARK: - 選択中タブの中身

struct BrowserPane: View {
    @ObservedObject var tab: Tab
    // ダウンロードはタブに属さないので、アプリ共通の一つを見る
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject var manager: TabManager
    @EnvironmentObject var store: BookmarkStore
    @State private var addressText: String = ""
    // アドレスバーを編集中か（AddressField からの通知で更新）
    @State private var addressEditing = false
    // 打った文字から組み立てた候補と、今どれを選んでいるか。
    // 先頭（0 番）は必ず「Return を押したら何が起きるか」なので、
    // 候補を見ずに打ち続ける限り、これまでと同じ動きになる
    @State private var suggestions: [AddressSuggestion] = []
    @State private var suggestionIndex = 0
    // 候補を選び終えたら編集を畳む合図（AddressField が受ける）
    @State private var addressEndEditingTrigger = 0
    // アドレスバー行の高さ。候補一覧をその真下へ落とすのに使う
    @State private var addressBarHeight: CGFloat = 0

    // 編集中で、かつ出すものがある時だけ垂らす
    private var showsSuggestions: Bool {
        addressEditing && !suggestions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // アドレスバーとブックマークバーは、疑似大画面（動画が
            // ウィンドウを占有）中は隠して、全面を Web の中身に明け渡す
            if !tab.isVideoFullscreen {
            // ── アドレスバー ──
            HStack(spacing: 10) {
                historyButtons
                NavButton(system: "arrow.clockwise", disabled: false)           { tab.reload() }

                // アドレスバーは AppKit 直書き（AddressField）。
                // 確定は delegate の insertNewline でのみ行い、target/action は
                // 使わない（action は編集終了でも発火し、ページをクリックした
                // だけで再読み込みが走る事故の再演になるため）。
                // クリックでの全選択（Safari と同じ挙動）は AddressField 内の
                // AppKit 実装が決定論的に行う。編集終了時は打ちかけを捨てて
                // 現在の URL に戻す（Return 確定時は submitAddress が先に
                // urlText を更新しているので影響なし）
                addressBar

                trailingControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Deco.panel)
            // ── 候補一覧 ──
            //
            // アドレスバーの下へ垂らす。位置は行の高さを実測して下げるだけで、
            // alignmentGuide の解決には頼らない——overlay の .bottom に
            // 「自分の上端」を差し出す手は効かず、一覧の下端が行の下端に
            // 揃えられて上へ伸び、二行目からタイトルバーに切られていた。
            //
            // fixedSize が要るのは、overlay の子には親（＝アドレスバー行）の
            // 高さしか差し出されないため。そのままだと数十ポイントに
            // 押し込められて、行が潰れる。
            //
            // zIndex はブックマークバーや Web の中身より前に出すため
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                addressBarHeight = height
            }
            .overlay(alignment: .top) {
                if showsSuggestions {
                    SuggestionList(
                        suggestions: suggestions,
                        selected: suggestionIndex,
                        onHover: { suggestionIndex = $0 },
                        onChoose: choose
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: addressBarHeight)
                }
            }
            .zIndex(1)

            // ── ブックマークバー ──
            BookmarkBar(tab: tab, manager: manager)

            // ── ページ内検索バー（⌘F）──
            // タブごとに作り直す。使い回すと、前のタブで編集中だった
            // フィールドエディタが残って打ちかけの語が混ざる
            if tab.isFindBarVisible {
                FindBar(tab: tab).id(tab.id)
            }

            // ── ポップアップを止めた知らせ ──
            if !tab.blockedPopups.isEmpty {
                PopupNoticeBar(tab: tab)
            }

            // ── ログイン情報の預かりについての問い ──
            PasswordNoticeBar(tab: tab)

            // ── ダウンロードの棚 ──
            if downloads.isShelfVisible, !downloads.items.isEmpty {
                DownloadShelf(downloads: downloads)
            }
            }

            // ── 中身：ロビー or Web ──
            // 全タブの WebView を常に画面に置き、選択中の一枚だけを見せる。
            // NSViewRepresentable は一度作った NSView を使い回すので、
            // 単一の WebView 枚だとタブを切り替えても最初の WebView が表示され続ける。
            // また、常時マウントにより裏タブの読み込み・タイトル更新も進む
            ZStack {
                ForEach(manager.tabs) { t in
                    // 顛末書を出している間は WebView を伏せる。
                    // 上に重ねて隠すのではなく引っ込めるのは、AppKit のビューと
                    // SwiftUI の重なり順を当てにしないため（ロビーと同じ手）。
                    // loadError を選択中のタブ（tab）から読むのは、
                    // BrowserPane が見張っているのがそれだけだから——
                    // 条件に t.id == tab.id が入っているので同じものを指す
                    let showsWeb = t.id == tab.id && !t.isHome && tab.loadError == nil
                    WebView(webView: t.webView, isInteractive: showsWeb)
                        .opacity(showsWeb ? 1 : 0)
                        .allowsHitTesting(showsWeb)
                        // 器を作り直したら、こちらの器も組み直させる。
                        //
                        // updateNSView は WKWebView の親子関係に一切触らない
                        //（全画面再生を壊さないための判断。詳しくは WebView の中）。
                        // だから中身を差し替えても、そこには何も届かない。
                        // .id を変えて makeNSView からやり直させる——
                        // 器ごと新しく作るので、付け替えをめぐる上の話とは土俵が違う
                        .id(t.webViewGeneration)
                }
                if let error = tab.loadError {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(tab.pageTitle.isEmpty ? "Skyscraper" : tab.pageTitle)
        .onAppear {
            addressText = tab.urlText
        }
        .onChange(of: tab.id) { _, _ in
            addressText = tab.urlText
            clearSuggestions()
        }
        .onChange(of: tab.urlText) { _, newValue in
            if !addressEditing {
                addressText = newValue
            }
        }
        // 打つそばから組み立て直す。
        // 編集中かどうかで絞らないのは、受け身の焦点のままいきなり
        // 打ち始めた場合、編集開始の知らせが一拍遅れて届くため
        //（出す・出さないは showsSuggestions が持つ）
        .onChange(of: addressText) { _, _ in
            refreshSuggestions()
        }
        .onChange(of: tab.addressBarFocusTrigger) { _, _ in
            // フォーカスと全選択は AddressField 側が focusTrigger の変化で行う。
            // ここでは表示文字列を現在の URL に揃えるだけ
            addressText = tab.urlText
        }
    }

    // ── 戻る／進む ──
    //
    // 短く押せば普段どおり。押しっぱなし（か右クリック）で履歴の一覧が垂れる。
    // 一覧を作るのはメニューを開く直前だけだ——
    // 描き直しのたびに WKBackForwardList をなぞる理由は無い
    @ViewBuilder
    private var historyButtons: some View {
        HStack(spacing: 10) {
            HoldNavButton(
                system: "chevron.left",
                disabled: !tab.canGoBack,
                action: { tab.goBack() },
                titles: { tab.backHistory.map { Tab.historyLabel(for: $0) } },
                onSelect: { index in
                    let items = tab.backHistory
                    guard items.indices.contains(index) else { return }
                    tab.go(to: items[index])
                }
            )
            .frame(width: 24, height: 24)

            HoldNavButton(
                system: "chevron.right",
                disabled: !tab.canGoForward,
                action: { tab.goForward() },
                titles: { tab.forwardHistory.map { Tab.historyLabel(for: $0) } },
                onSelect: { index in
                    let items = tab.forwardHistory
                    guard items.indices.contains(index) else { return }
                    tab.go(to: items[index])
                }
            )
            .frame(width: 24, height: 24)
        }
    }

    // ── アドレスバー本体と、その左に立つ鍵 ──
    //
    // 切り出してあるのは下の trailingControls と同じ理由だ。
    // 鍵と欄を HStack で束ねたのは、六角形の枠を二つに割らないため——
    // 鍵は欄の外に置かれた別のボタンではなく、同じ一枚の札の上にある
    private var addressBar: some View {
        HStack(spacing: 8) {
            // 接続の格を示す鍵。押すとサイトの調書が垂れる（SiteInfo.swift）
            SiteSecurityButton(tab: tab)

            AddressField(
                text: $addressText,
                tabToken: tab.id,
                tabURL: tab.urlText,
                focusTrigger: tab.addressBarFocusTrigger,
                endEditingTrigger: addressEndEditingTrigger,
                onSubmit: submitAddress,
                onEditingChanged: { editing in
                    addressEditing = editing
                    if !editing {
                        addressText = tab.urlText
                        clearSuggestions()
                    }
                },
                onMove: moveSelection,
                onCancel: dismissSuggestions
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Hexagon(inset: 6).fill(Deco.field))
        .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
    }

    // ── アドレスバー右端の道具 ──
    //
    // body から切り出してあるのは、型検査を軽くするため。
    // 条件分岐が一つ増えるたびに ViewBuilder は分岐の型を
    // 入れ子に積むので、三つ並べて上に三項演算子を重ねると
    // 式全体が膨らんで、型検査が時間切れを起こす。
    // 見た目も動きも変わらない——置き場所を移しただけだ
    @ViewBuilder
    private var trailingControls: some View {
        // 拡張機能のボタン。
        // 拡張が無ければ何も出ないので、幅を食わない
        WebExtensionActionBar(tab: tab)

        // リーダーモードボタン。本文のあるページでだけ現れる
        if tab.isReaderAvailable {
            Button {
                tab.toggleReader()
            } label: {
                Image(systemName: tab.isReaderActive ? "book.fill" : "book")
                    .font(.system(size: 13))
                    .foregroundColor(tab.isReaderActive ? Deco.cream : Deco.gold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(tab.isReaderActive ? "Hide Reader" : "Show Reader")
        }

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

        // ダウンロードの棚を開け閉めする。
        // 今回の起動で何か落としていれば現れる
        if !downloads.items.isEmpty {
            Button {
                downloads.isShelfVisible.toggle()
            } label: {
                Image(systemName: downloads.hasActive
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundColor(downloads.isShelfVisible ? Deco.cream : Deco.gold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Downloads")
        }

        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(Deco.gold)
        }
    }

    private func submitAddress() {
        // 選んでいる候補があればそれに従う。
        // 何も触っていなければ選択は先頭＝入力そのものの解釈なので、
        // 結局は下の道と同じ場所へ行く
        if showsSuggestions, suggestions.indices.contains(suggestionIndex) {
            choose(suggestions[suggestionIndex])
            return
        }
        let targetTab = manager.selectedTab ?? tab
        targetTab.urlText = addressText
        targetTab.load()
    }

    // 候補を実行する（Return でも、行を押した時でも通る）
    private func choose(_ suggestion: AddressSuggestion) {
        let targetTab = manager.selectedTab ?? tab
        switch suggestion.kind {
        case .navigate(let text), .search(let text):
            // 整形していない入力をそのまま渡す。
            // load() が resolveURL に通すので、一覧に出したのと同じ判断になる
            targetTab.urlText = text
            targetTab.load()
        case .bookmark(let url):
            targetTab.urlText = url
            targetTab.load()
        case .openTab(let id):
            if let target = manager.tabs.first(where: { $0.id == id }) {
                manager.select(target)
            }
        }
        clearSuggestions()
        // 欄に打ちかけを残さない。畳んだ拍子に現在の URL が映る
        addressEndEditingTrigger += 1
    }

    private func refreshSuggestions() {
        let query = addressText.trimmingCharacters(in: .whitespaces)
        // ⌘L で全選択しただけの状態では出さない。
        // 今いる場所をなぞった候補が出ても邪魔になるだけ
        guard !query.isEmpty, query != tab.urlText else {
            clearSuggestions()
            return
        }
        let others = manager.tabs
            .filter { $0.id != tab.id }
            .map { TabCandidate(id: $0.id, title: $0.pageTitle, url: $0.urlText) }
        suggestions = AddressSuggestions.build(query: query,
                                               bookmarks: store.bookmarks,
                                               tabs: others)
        suggestionIndex = 0
    }

    // ↑↓。端まで来たら巻き戻す（候補は数行なので、行き止まりより回った方が速い）
    private func moveSelection(_ offset: Int) -> Bool {
        guard showsSuggestions else { return false }
        let count = suggestions.count
        suggestionIndex = ((suggestionIndex + offset) % count + count) % count
        return true
    }

    // Esc の一度目。候補を閉じるだけで、打ちかけの語は残す。
    // 二度目は false を返すので、AppKit 既定の「捨てて URL に戻す」へ落ちる
    private func dismissSuggestions() -> Bool {
        guard showsSuggestions else { return false }
        clearSuggestions()
        return true
    }

    private func clearSuggestions() {
        suggestions = []
        suggestionIndex = 0
    }
}

// MARK: - 翻訳パネル

// 右端に引き出す縦長の盤。原文と訳文を上下に並べる。
// 縦タブの帯と左右対称になる位置だ
//
// 幅を固定にしてあるのは、Web の中身の幅が開け閉めのたびに
// 跡形もなく変わると、ページ側の再レイアウトが重いため
struct TranslationPanel: View {
    @ObservedObject var translator: Translator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Zigzag(teeth: 16)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            languageRow
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    caption("Original")
                    Text(verbatim: translator.sourceText)
                        .font(.system(size: 12, design: .serif))
                        .foregroundColor(Deco.dimGold)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Deco.faintGold)
                        .frame(height: 1)
                        .padding(.vertical, 4)

                    caption("Translation")
                    result
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            footer
        }
        .frame(width: 320)
        .background(Deco.panel)
        // 左端に一本罫を引いて、Web の中身との境をはっきりさせる
        .overlay(alignment: .leading) {
            Rectangle().fill(Deco.faintGold).frame(width: 1)
        }
    }

    // ── 見出し ──

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 11))
                .foregroundColor(Deco.gold)

            Text("Translation")
                .font(.system(size: 12, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.cream)

            Spacer()

            Button { translator.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(Deco.dimGold)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // ── 判定された言語 → 訳先 ──

    private var languageRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: translator.detectedLanguageName)
                .font(.system(size: 11, design: .serif))
                .foregroundColor(Deco.gold)
                .lineLimit(1)

            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(Deco.faintGold)

            Menu {
                ForEach(translator.availableLanguages, id: \.self) { language in
                    Button(Translator.displayName(of: language)) {
                        translator.targetLanguage = language
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(verbatim: Translator.displayName(of: translator.targetLanguage))
                        .font(.system(size: 11, design: .serif))
                        .foregroundColor(Deco.cream)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(Deco.dimGold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: 0)
        }
    }

    // ── 訳文（もしくは途中経過）──

    @ViewBuilder
    private var result: some View {
        switch translator.phase {
        case .idle:
            EmptyView()

        case .preparing:
            // 初回の言語はここでシステムのダウンロード確認が出る。
            // 無言で待たせると壊れたように見えるので、別の文言にする
            busy("Preparing the language…")

        case .translating:
            busy("Translating…")

        case .done(let text):
            Text(verbatim: text)
                .font(.system(size: 13, design: .serif))
                .foregroundColor(Deco.cream)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message)
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                chipButton("Try Again") { translator.retry() }
            }
        }
    }

    private func busy(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Deco.gold)
            Text(title)
                .font(.system(size: 11, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.dimGold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── 足元 ──

    @ViewBuilder
    private var footer: some View {
        if let text = translator.translatedText {
            VStack(spacing: 0) {
                Rectangle().fill(Deco.faintGold).frame(height: 1)
                HStack {
                    Spacer()
                    chipButton("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // ── 部品 ──

    private func caption(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 9, design: .serif))
            .tracking(2)
            .foregroundColor(Deco.faintGold)
    }

    private func chipButton(_ title: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 全体

struct ContentView: View {
    // 管理人は窓ごとに一人。ここを App 直下から移したことで、
    // ⌘N で窓を増やせばタブも別々になる
    @StateObject private var manager = TabManager()
    // 翻訳も窓ごと。盤が窓の右端に一つだから、タブではなく窓に付ける
    @StateObject private var translator = Translator()
    // ブックマークは窓をまたいで共通なので、外から受け取る
    @ObservedObject var bookmarks: BookmarkStore
    @Environment(\.openWindow) private var openWindow

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

            // 翻訳の盤。疑似大画面中はサイドバーと同じく引っ込める
            if translator.isPresented, manager.selectedTab?.isVideoFullscreen != true {
                TranslationPanel(translator: translator)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.18), value: translator.isPresented)
        .frame(minWidth: 900, minHeight: 600)
        .background(Deco.ink)
        .environmentObject(bookmarks)
        .preferredColorScheme(.dark)
        // この窓が手前に来たら、自分の管理人と翻訳役をメニューに差し出す
        .focusedSceneValue(\.tabManager, manager)
        .focusedSceneValue(\.translator, translator)
        // TranslationSession は自前で作れない。このモディファイアからしか
        // 降ってこないので、翻訳の本体はここで受け取って Translator に渡す。
        // configuration の中身が変わるか、invalidate() されると発火する
        .translationTask(translator.configuration) { session in
            await translator.perform(with: session)
        }
        .onAppear {
            manager.markOpen()
            // 復元待ちがまだ残っていれば、次の窓を開く。
            // 開いた先も同じことをするので、必要な枚数まで数珠つなぎに続く。
            // この窓の分は既に manager の初期化で取り出されている
            if TabManager.hasPendingRestores {
                openWindow(id: "browser")
            }
        }
        .onDisappear {
            // 窓を閉じたことを伝える。
            // SwiftUI は閉じても @StateObject を温存するので、
            // 解放されるのを待っても名簿から消えない
            manager.markClosed()
        }
        // タブを新しい窓へ移す合図。
        // openWindow は環境にしか無いので、窓を開くのはここの仕事だ
        .onChange(of: manager.newWindowRequests) { _, _ in
            openWindow(id: "browser")
        }
    }
}

#Preview {
    ContentView(bookmarks: BookmarkStore())
}
