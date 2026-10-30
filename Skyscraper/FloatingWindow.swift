//
//  FloatingWindow.swift
//  Skyscraper
//
//  浮かぶ小窓。タブを丸ごと、常に手前に浮く小さな窓へ移す。
//
//  ── なぜ PiP ではないのか ──
//  macOS の WKWebView には PiP を開く公開の口が無い (Tab.makeWebView の注記)。
//  そこでタブの WKWebView そのものを小窓へ載せ替え、ページの中の動画だけを
//  窓いっぱいに広げる。X 用のシアターモード (ContentView の媒体の見張り) と
//  同じ「動画までの道の外を隠す」手を、どのサイトにも効く形で持ってある。
//  動画の無いページなら、ページをそのまま小窓で見せる。
//
//  ── 載せ替えの決まり ──
//  WKWebView は一度に一つの親にしか居られない。小窓に出している間、
//  元の窓の器 (BrowserPane の ZStack) はそのタブの WebView を作らず、
//  「小窓で再生中」の札を出す。戻す時は Tab.isFloating を倒すだけで、
//  元の窓の器が作り直され、mount が WebView を引き取る。
//
//  小窓は一度に一枚。別のタブを浮かべると、前のタブは元へ戻る。
//  小窓を閉じたら、タブに戻って再生を続ける
//

import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class FloatingPlayer: NSObject, NSWindowDelegate {
    static let shared = FloatingPlayer()

    private(set) weak var tab: Tab?
    private weak var manager: TabManager?
    private var panel: NSPanel?
    // ページを移ったら広げ直すための見張り
    private var loadWatch: AnyCancellable?
    // 戻す処理の二重起動止め (panel.close が windowWillClose を呼ぶため)
    private var isReturning = false

    // 小窓の位置と大きさを覚える名前。次に浮かべた時も同じ所に出る
    private static let frameName = "SkyscraperFloatingWindow"

    // メニュー・案内板・アドレスバーの釦はここを呼ぶ
    func toggle(_ tab: Tab, in manager: TabManager) {
        if self.tab === tab {
            returnToTab()
        } else {
            float(tab, in: manager)
        }
    }

    func float(_ tab: Tab, in manager: TabManager) {
        // ロビーには浮かべる物が無い
        guard !tab.isHome, !tab.isUnloaded else { return }
        if self.tab != nil { returnToTab() }

        self.tab = tab
        self.manager = manager
        tab.isFloating = true
        // Skyscraper が前に居ない時の一回目のクリックも、ページへ届ける
        (tab.webView as? SkyscraperWebView)?.acceptsFirstMouseAlways = true

        let panel = makePanel(for: tab)
        self.panel = panel
        panel.orderFrontRegardless()

        // WebView が小窓に載り終わってから広げる。
        // 載せ替えの途中 (どの窓にも居ない間) に動画の配置を変えると、
        // WebKit が動画の絵の層を作り直さず、小窓が黒いままになった
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab else { return }
            self.applyFloatStyle(fitAspect: true)
        }
        // ページを移ると広げた CSS ごと消えるので、読み終わるたびに広げ直す
        loadWatch = tab.$isLoading
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] loading in
                if !loading { self?.applyFloatStyle(fitAspect: false) }
            }
    }

    // 元のタブへ戻す。reveal なら、そのタブを選んで元の窓を前に出す
    func returnToTab(reveal: Bool = false) {
        guard let tab, !isReturning else { return }
        isReturning = true
        defer { isReturning = false }

        loadWatch = nil
        tab.webView.evaluateJavaScript(Self.exitScript, completionHandler: nil)

        let panel = self.panel
        let owner = manager
        self.panel = nil
        self.tab = nil
        manager = nil

        (tab.webView as? SkyscraperWebView)?.acceptsFirstMouseAlways = false

        // 倒せば元の窓の器が作り直され、WebView を引き取る。
        // 元の窓が見張っているのは選ばれているタブだけなので、
        // 浮いている間に別のタブへ移っていた場合に備えて管理人も揺らす
        tab.isFloating = false
        owner?.objectWillChange.send()
        panel?.delegate = nil
        panel?.contentView = nil
        panel?.close()

        if reveal {
            NSApp.activate()
            TabManager.reveal(tabID: tab.id)
        }

        // ページは小窓の大きさに合わせて組み直したままになっている。
        // 元の窓へ戻った後で「窓の大きさが変わった」と知らせ、組み直させる。
        // (YouTube は WebView の器が変わっただけでは再生器の大きさを測り直さなかった)
        // 器の付け替えは次の描き直しで起きるので、少し待ってから二度鳴らす
        let webView = tab.webView
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                webView.evaluateJavaScript(Self.resizeScript, completionHandler: nil)
            }
        }
    }

    // タブが閉じられる・別の窓へ移される時
    func release(_ tab: Tab) {
        if self.tab === tab { returnToTab() }
    }

    // 窓が閉じる時。その窓のタブが浮いていたら戻して (一緒に片付けられるように)
    func release(manager: TabManager) {
        if self.manager === manager { returnToTab() }
    }

    // 小窓が何かの拍子に閉じられた時の受け口
    func windowWillClose(_ notification: Notification) {
        returnToTab()
    }

    // ── 小窓 ──

    private func makePanel(for tab: Tab) -> NSPanel {
        let size = NSSize(width: 480, height: 270)
        let screen = (tab.webView.window?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)

        // 押しても Skyscraper を前に出さない (.nonactivatingPanel)。
        // 他のアプリで作業しながら、小窓だけを触れるように
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.titled, .closable, .resizable,
                                        .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        // 既定では他のアプリへ移ると消える。小窓はそれでは困る
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.minSize = NSSize(width: 240, height: 135)
        panel.title = tab.pageTitle
        // 信号機は出さない。閉じる・戻すは見出しの釦で
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingView(
            tab: tab,
            onReturn: { [weak self] in self?.returnToTab(reveal: true) },
            onClose: { [weak self] in self?.returnToTab() }
        ))
        // 前に置いた場所があればそこへ (無ければ右下)
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    // ページの中の動画を窓いっぱいに広げる。
    // fitAspect なら、動画の縦横比に小窓を合わせる (浮かべた最初の一回だけ)
    private func applyFloatStyle(fitAspect: Bool) {
        guard let tab else { return }
        tab.webView.evaluateJavaScript(Self.enterScript) { [weak self] result, _ in
            guard fitAspect,
                  let self, let panel = self.panel,
                  let size = result as? [String: Any],
                  let w = (size["w"] as? NSNumber)?.doubleValue,
                  let h = (size["h"] as? NSNumber)?.doubleValue,
                  w > 0, h > 0 else { return }
            panel.contentAspectRatio = NSSize(width: w, height: h)
            var frame = panel.frame
            let height = frame.width * h / w
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    // ── ページ側 ──
    //
    // 動画の選び方：再生中のものの中で一番大きいもの。
    // 再生中が無ければ、見えているものの中で一番大きいもの。
    //
    // 動画から <html> までの道の上の先祖は transform などを外して
    // position: fixed を本来の意味 (窓基準) に戻し、道の外の兄弟は隠す。
    // 先祖の overflow・角丸・content-visibility も外す——YouTube の再生器は
    // 角丸＋はみ出し切り落としの枠で、WebKit は窓基準に広げた動画まで
    // その枠で切り落とし、小窓が真っ黒になった
    // サイトの操作盤も隠れるので、代わりに小窓の下端に自前の操作盤を出す。
    // クリックは動画の外へ漏らさない——サイトの再生器が同じクリックで
    // もう一度一時停止を切り替え、打ち消し合うため
    private static let enterScript = """
    (() => {
        const S = window.__skyscraperFloat || (window.__skyscraperFloat = {});
        if (!document.getElementById('__skyscraper-float-style')) {
            const style = document.createElement('style');
            style.id = '__skyscraper-float-style';
            style.textContent =
                '.__skyscraper-float-video { position: fixed !important; inset: 0 !important; ' +
                'left: 0 !important; top: 0 !important; margin: 0 !important; ' +
                'width: 100vw !important; height: 100vh !important; ' +
                'max-width: none !important; max-height: none !important; ' +
                'object-fit: contain !important; transform: none !important; ' +
                'z-index: 2147483647 !important; background: #000 !important; } ' +
                '.__skyscraper-float-ancestor { transform: none !important; filter: none !important; ' +
                'perspective: none !important; contain: none !important; ' +
                'will-change: auto !important; clip-path: none !important; z-index: auto !important; ' +
                'overflow: visible !important; border-radius: 0 !important; ' +
                'content-visibility: visible !important; mask: none !important; ' +
                '-webkit-mask: none !important; } ' +
                '.__skyscraper-float-hidden { visibility: hidden !important; }';
            (document.head || document.documentElement).appendChild(style);
        }
        S.exit?.();

        const area = v => { const r = v.getBoundingClientRect(); return r.width * r.height; };
        const videos = Array.from(document.querySelectorAll('video'));
        const playing = videos.filter(v => !v.paused && !v.ended && v.readyState > 1);
        const pool = (playing.length ? playing : videos.filter(v => area(v) > 0))
            .sort((a, b) => area(b) - area(a));
        const video = pool[0];
        if (!video) { return null; }

        const ancestors = [];
        const hidden = [];
        let node = video;
        while (node && node.parentElement) {
            const parent = node.parentElement;
            for (const sibling of parent.children) {
                if (sibling !== node && !sibling.classList.contains('__skyscraper-float-hidden')) {
                    sibling.classList.add('__skyscraper-float-hidden');
                    hidden.push(sibling);
                }
            }
            if (parent === document.documentElement) { break; }
            parent.classList.add('__skyscraper-float-ancestor');
            ancestors.push(parent);
            node = parent;
        }

        video.classList.add('__skyscraper-float-video');
        const stop = event => event.stopPropagation();
        const kinds = ['click', 'dblclick', 'mousedown', 'mouseup', 'pointerdown', 'pointerup'];
        kinds.forEach(kind => video.addEventListener(kind, stop));
        // 一時停止と再生の切り替え。動画を押した時と、小窓の操作盤の釦から呼ぶ。
        // サイトの再生器へは上でクリックを渡さないので、ここで受け持つ
        const flip = () => {
            if (video.paused || video.ended) { video.play().catch(() => {}); } else { video.pause(); }
        };
        const toggle = event => { event.preventDefault(); flip(); };
        video.addEventListener('click', toggle);

        // 小窓の操作盤 (FloatingControls) が読み書きする口。
        // ネイティブの操作盤 (controls) は使わない——YouTube は付けてもすぐ外し直す
        S.state = () => ({
            ok: true,
            t: video.currentTime || 0,
            d: isFinite(video.duration) ? video.duration : 0,
            p: video.paused || video.ended
        });
        S.toggle = flip;
        S.skip = dt => {
            const end = isFinite(video.duration) ? video.duration : Infinity;
            video.currentTime = Math.max(0, Math.min(end, video.currentTime + dt));
        };
        S.seek = t => { video.currentTime = t; };

        S.exit = () => {
            video.removeEventListener('click', toggle);
            kinds.forEach(kind => video.removeEventListener(kind, stop));
            video.classList.remove('__skyscraper-float-video');
            S.state = null;
            S.toggle = null;
            S.skip = null;
            S.seek = null;
            ancestors.forEach(n => n.classList.remove('__skyscraper-float-ancestor'));
            hidden.forEach(n => n.classList.remove('__skyscraper-float-hidden'));
            S.exit = null;
        };
        // 今の位置へシークし直して、広げた後の大きさで絵を一枚描かせる。
        // 読み込み済みの範囲なので、通信も待ちも起きない
        if (video.readyState > 1 && !video.ended) {
            try { video.currentTime = video.currentTime; } catch (e) {}
        }
        return { w: video.videoWidth, h: video.videoHeight };
    })();
    """

    private static let exitScript = "window.__skyscraperFloat?.exit?.();"

    private static let resizeScript = "window.dispatchEvent(new Event('resize'));"
}

// MARK: - 小窓の中身

struct FloatingView: View {
    @ObservedObject var tab: Tab
    let onReturn: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        // 黒の下地は ZStack に並べず、background に回す。
        // SwiftUI の塗りと AppKit のビュー (WebView) を同じ段に並べると、
        // どちらが上に描かれるかが当てにならない——塗りが WebView を覆って真っ黒になった
        ZStack(alignment: .top) {
            WebView(webView: tab.webView, isInteractive: true)
                .id(tab.webViewGeneration)
            // 見出し。カーソルが乗った時だけ出る。
            // 窓を掴んで動かすのもここ (WebView の上では掴めないため)
            header
                .opacity(isHovering ? 1 : 0)
        }
        // 下端の操作盤。広げた動画がある時だけ、カーソルが乗っている間に出る
        .overlay(alignment: .bottom) {
            FloatingControls(webView: tab.webView, isActive: isHovering)
                .opacity(isHovering ? 1 : 0)
        }
        .background(Color.black)
        .overlay(Rectangle().stroke(Deco.gold.opacity(isHovering ? 0.8 : 0.35), lineWidth: 1))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovering)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 5))
                .foregroundColor(Deco.gold)
            Text(verbatim: tab.pageTitle)
                .font(.system(size: 11, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.cream)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onReturn) {
                Image(systemName: "pip.exit")
                    .font(.system(size: 12))
                    .foregroundColor(Deco.gold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Back to Tab")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Deco.gold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(WindowDragArea())
        .background(
            LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

// 掴むと窓ごと動く下敷き。見出しの釦は上に乗っているので邪魔しない
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: - 元の窓に出す札

struct FloatingPlaceholder: View {
    let onBringBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pip")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Deco.gold)
            Text("Playing in a floating window")
                .font(.system(size: 13, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.cream)
            Button(action: onBringBack) {
                Text("Bring Back")
                    .font(.system(size: 12, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .overlay(Hexagon(inset: 7).stroke(Deco.faintGold, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deco.ink)
        .overlay { LobbyFrame() }
    }
}

// MARK: - 小窓の操作盤

// シークバー・経過時間・10秒戻る・再生/一時停止・10秒進む。
// 中身はページの動画に問い合わせて知る (enterScript が生やす口)。
// 問い合わせはカーソルが乗っている間だけ、半秒ごとに回す
private struct FloatingControls: View {
    let webView: WKWebView
    let isActive: Bool

    @State private var hasVideo = false
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var isPaused = false
    // シークバーを掴んでいる間の位置。離すまで動画には送らない
    @State private var scrubbing: Double?

    var body: some View {
        Group {
            if hasVideo {
                panel
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 2) {
            // 生放送は長さが無いので、シークバーを出さない
            if duration > 0 {
                Slider(
                    value: Binding(get: { scrubbing ?? position },
                                   set: { scrubbing = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubbing else { return }
                        position = target
                        scrubbing = nil
                        run("window.__skyscraperFloat?.seek?.(\(target))")
                    }
                )
                .controlSize(.mini)
                .tint(Deco.gold)
            }
            HStack(spacing: 16) {
                Text(verbatim: Self.clock(scrubbing ?? position))
                    .frame(width: 56, alignment: .leading)
                Spacer()
                control("gobackward.10") { run("window.__skyscraperFloat?.skip?.(-10)") }
                control(isPaused ? "play.fill" : "pause.fill", size: 15) {
                    isPaused.toggle()
                    run("window.__skyscraperFloat?.toggle?.()")
                }
                control("goforward.10") { run("window.__skyscraperFloat?.skip?.(10)") }
                Spacer()
                Text(verbatim: duration > 0 ? Self.clock(duration) : "LIVE")
                    .frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 10, design: .serif))
            .monospacedDigit()
            .foregroundColor(Deco.dimGold)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func control(_ symbol: String, size: CGFloat = 13,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(Deco.gold)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // 広げた動画の今の様子を聞く。広げていない (動画の無いページ) なら ok: false が返る
    private func refresh() async {
        let script = """
        (window.__skyscraperFloat && window.__skyscraperFloat.state)
            ? window.__skyscraperFloat.state() : { ok: false }
        """
        guard let state = try? await webView.evaluateJavaScript(script) as? [String: Any],
              (state["ok"] as? Bool) == true else {
            hasVideo = false
            return
        }
        hasVideo = true
        position = (state["t"] as? NSNumber)?.doubleValue ?? 0
        duration = (state["d"] as? NSNumber)?.doubleValue ?? 0
        isPaused = (state["p"] as? Bool) ?? false
    }

    // 秒を 3:07 / 1:02:45 の形に
    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
