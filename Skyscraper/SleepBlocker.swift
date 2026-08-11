//
//  SleepBlocker.swift
//  Skyscraper
//
//  動画を再生している間、スクリーンセーバーと画面のスリープを止める番人。
//
//  macOS には「今こういう用事をしているから寝るな」と宣言する仕組みがある
//  （ProcessInfo.beginActivity）。.idleDisplaySleepDisabled を立てている間は
//  無操作タイマーが進まなくなり、画面が暗くならず、スクリーンセーバーも出ない。
//  終わったら endActivity で必ず返す。返し忘れると永久に寝なくなるので、
//  宣言と返却は必ずこのクラス一箇所に閉じ込める。
//
//  厄介なのは「動画が再生中か」の判定だ。WKWebView には
//  requestMediaPlaybackState(_:) があるが、音だけの再生と区別が付かない。
//  ラジオや podcast まで画面を点けっぱなしにするのは違う。
//  なので各フレームに小さな見張りを仕込み、動画が流れている間だけ
//  4秒おきに「生きてるぞ」の合図（心拍）を送らせる。
//
//  心拍方式にしたのは、フレームの出入りを数えなくて済むからだ。
//  iframe 内の埋め込み動画（ブログに貼られた YouTube など）も同じ合図を送る。
//  誰か一人でも送っていれば止める、10秒間誰からも来なければ返す。それだけ。
//  フレームが動画を流したまま消し飛んでも、心拍が途絶えれば勝手に片付く。
//
//  ただし数えるのは「各窓で今見ているタブ」からの心拍だけだ。
//  裏タブで動画を流しっぱなしにしても画面は普通に寝る（他のブラウザも同じ）。
//  誰が選ばれているかは TabManager が selectedID の変化のたびに
//  noteSelection(_:in:) で知らせてくる。こちらから見に行かないのは、
//  窓の名簿（TabManager.registry）が向こうの内側のものだからだ。
//
//  止め始めが最大4秒、止め終わりが最大10秒遅れるが、
//  スクリーンセーバーの発動は最短でも1分先なので実害は無い。
//

import Foundation
import WebKit

@MainActor
final class SleepBlocker: NSObject, WKScriptMessageHandler {
    static let shared = SleepBlocker()

    static let messageHandlerName = "skyscraperVideoBeat"
    // 設定画面のトグルと共有する鍵。既定は「止める」
    static let enabledKey = "skyscraper.preventSleepDuringVideo"

    // 心拍が途絶えたと見なすまでの猶予（JS 側の間隔 4 秒の倍以上を取る）
    private static let expiry: TimeInterval = 10

    // 最後に心拍を受け取った時刻
    private var lastBeat: Date = .distantPast
    // 宣言中の用事。nil なら何も止めていない
    private var activity: NSObjectProtocol?
    private var watchdog: Timer?

    // 窓（TabManager）ごとの「今見ている WebView」。
    // 弱参照で持つ。強く持つと閉じた窓の WebView を抜けなくなるし、
    // ObjectIdentifier だけを控えると、解放後の番地を新しい誰かが
    // 使い回した時に人違いを起こす
    private struct WeakWebView {
        weak var webView: WKWebView?
    }
    private var selected: [ObjectIdentifier: WeakWebView] = [:]

    private override init() {
        super.init()
        // 心拍が途絶えたことは「来ない」ことでしか分からないので、
        // こちらから定期的に見に行く。
        // .common モードで登録しないと、メニューを開いている間などに止まる
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in SleepBlocker.shared.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: - 各タブから呼ぶ

    // 見張りの仕込み。全フレームに入れる（埋め込み動画も拾いたい）
    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )

    // MARK: - 窓から呼ぶ

    // この窓で今見ているタブの WebView を告げる（nil でこの窓を名簿から外す）。
    // TabManager の selectedID の didSet から呼ばれる。
    // 窓を閉じた時は tearDownTabs が selectedID を nil にするので、
    // その didSet でここにも nil が届いて勝手に片付く
    func noteSelection(_ webView: WKWebView?, in window: AnyObject) {
        let key = ObjectIdentifier(window)
        if let webView {
            selected[key] = WeakWebView(webView: webView)
        } else {
            selected.removeValue(forKey: key)
        }
        // 見ているタブが変わった直後は、前のタブの心拍がまだ
        // 10秒の内側に残っている。残りを切り上げて、新しいタブから
        // 心拍が来ない限り次の見回りで手を放す
        lastBeat = .distantPast
        evaluate()
    }

    // MARK: - 心拍の受け口

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName else { return }
        // 選ばれていないタブ（バックグラウンド再生）の心拍は数えない。
        // iframe からの合図でも message.webView はタブの WebView 自身なので、
        // この照合で埋め込み動画も正しく拾える
        guard let webView = message.webView,
              selected.values.contains(where: { $0.webView === webView }) else { return }
        lastBeat = Date()
        evaluate()
    }

    // MARK: - 宣言の出し入れ

    private func evaluate() {
        // 設定が無い（初回起動）なら止める側に倒す
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let awake = enabled && Date().timeIntervalSince(lastBeat) < Self.expiry

        if awake {
            guard activity == nil else { return }
            // .userInitiated ＝「利用者が始めた用事」。システムスリープも止まる。
            // .idleDisplaySleepDisabled が画面の消灯とスクリーンセーバーを抑える
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "Video playback"
            )
        } else {
            guard let token = activity else { return }
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    // MARK: - 見張りの中身

    private static let source = """
    (() => {
        if (window.__skyscraperSleepBlockerInstalled) { return; }
        window.__skyscraperSleepBlockerInstalled = true;

        // 心拍の間隔（ミリ秒）。アプリ側の猶予より十分短く保つこと
        const beatMs = 4000;

        // 「見るための動画」かどうか。
        // ・videoWidth が 0 ＝ まだ絵が無い（音声だけの <video> もここで落ちる）
        // ・小さすぎるものは飾りか計測用の隠し動画とみなす
        // ・loop かつ muted は、記事の背景に敷かれた装飾動画の典型。
        //   これで画面が点きっぱなしになるのは筋が違うので数えない
        //   （X の動画は loop ではないので、消音のまま見ていても数えられる）
        const watchable = (video) => {
            if (video.paused || video.ended) { return false; }
            if (!video.videoWidth) { return false; }
            if (video.loop && video.muted) { return false; }
            const rect = video.getBoundingClientRect();
            return rect.width >= 200 && rect.height >= 150;
        };

        setInterval(() => {
            const alive = Array.from(document.querySelectorAll('video')).some(watchable);
            if (!alive) { return; }
            window.webkit?.messageHandlers?.skyscraperVideoBeat?.postMessage(1);
        }, beatMs);
    })();
    """
}
