//
//  DownloadManager.swift
//  Skyscraper
//
//  ダウンロードの受け持ちと、画面下に出る棚（一覧）。
//
//  以前は Tab が WKDownloadDelegate を兼ねていたが、
//  ダウンロードはタブより長生きする（保存中にタブを閉じられる）。
//  持ち主をアプリ側へ移して、タブが消えても最後まで面倒を見る。
//
//  記録はメモリ上だけに置く。アプリを終了すれば消える。
//  落としたファイル自体は残るが、「いつ何を落としたか」は残さない。
//
//  一時停止と再開について。
//  WKDownload が返す resumeData は使わない。二度目の停止で中身が古いまま
//  返り、ファイルを頭から書き直して静かに壊すのを確認したため。
//  代わりに、再開位置は毎回ディスク上の実ファイルサイズから決める。
//  実サイズだけが唯一信用できる拠り所で、何度止めても狂わない。
//  続きの取得は自前の URLSession に Range を付けて投げ、
//  ファイルの末尾へ追記していく。
//

import SwiftUI
import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers
import CoreServices

// MARK: - 続きを取りに行く係

// URLSession の委任は主スレッドの外から呼ばれる。
// 直列のキューを一本立てて受けるので、内部で錠を掛ける必要はない。
final class ResumeDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Failure: LocalizedError {
        case badStatus(Int)
        case rangeMismatch
        case cannotOpenFile

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "HTTP \(code)"
            case .rangeMismatch:
                return String(localized: "The file on the server has changed")
            case .cannotOpenFile:
                return String(localized: "Could not open the file")
            }
        }
    }

    private let destination: URL
    private let offset: Int64
    private let onProgress: @Sendable (Int64) -> Void
    private let onFinish: @Sendable (Error?) -> Void

    private var handle: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var headers: [String: String] = [:]
    private var base: Int64 = 0          // 今回の書き出し開始位置
    private var written: Int64 = 0       // 今回書いた量
    private var lastReport = Date.distantPast
    private var finished = false

    init(destination: URL,
         offset: Int64,
         onProgress: @escaping @Sendable (Int64) -> Void,
         onFinish: @escaping @Sendable (Error?) -> Void) {
        self.destination = destination
        self.offset = offset
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func start(request: URLRequest) {
        headers = request.allHTTPHeaderFields ?? [:]

        let config = URLSessionConfiguration.default
        // Cookie は自分で組み立てて渡す。共有の入れ物には触らせない
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "net.live-on.inugamine.Skyscraper.resume"

        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            complete(with: Failure.badStatus(0))
            completionHandler(.cancel)
            return
        }

        switch http.statusCode {
        case 206:
            // Content-Range の開始位置が要求どおりかを必ず確かめる。
            // ここがずれたまま書き始めると、静かにファイルが壊れる
            let value = http.value(forHTTPHeaderField: "Content-Range")
            guard let value, Self.rangeStart(value) == offset else {
                print("[DL] resume: unexpected Content-Range \(value ?? "(none)") want \(offset)")
                complete(with: Failure.rangeMismatch)
                completionHandler(.cancel)
                return
            }
            guard open(truncate: false) else {
                complete(with: Failure.cannotOpenFile)
                completionHandler(.cancel)
                return
            }

        case 200:
            // Range を無視された。中身が入れ替わっている恐れもあるので、頭から書き直す
            print("[DL] resume: server ignored Range, restarting from the beginning")
            guard open(truncate: true) else {
                complete(with: Failure.cannotOpenFile)
                completionHandler(.cancel)
                return
            }

        default:
            complete(with: Failure.badStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            complete(with: error)
            dataTask.cancel()
            return
        }
        written += Int64(data.count)

        // 毎回主スレッドを叩くと表示のためだけに負荷が乗る。間引く
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.1 {
            lastReport = now
            onProgress(base + written)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 飛ばされた先にも Range を引き継ぐ。
        // 落とすと全体が返ってきて、それに気付かず追記すれば壊れる
        var next = request
        for key in ["Range", "If-Range", "Accept-Encoding", "Cookie", "User-Agent"] {
            if let value = headers[key] {
                next.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        complete(with: error)
    }

    // MARK: - 中身

    private func open(truncate: Bool) -> Bool {
        do {
            let handle = try FileHandle(forWritingTo: destination)
            if truncate {
                try handle.truncate(atOffset: 0)
                base = 0
            } else {
                try handle.seekToEnd()
                base = offset
            }
            self.handle = handle
            return true
        } catch {
            print("[DL] resume: could not open \(destination.path): \(error.localizedDescription)")
            return false
        }
    }

    private func complete(with error: Error?) {
        guard !finished else { return }
        finished = true
        try? handle?.close()
        handle = nil
        onProgress(base + written)
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish(error)
    }

    // 「bytes 1802015876-6482409471/6482409472」から先頭の数を取り出す
    private static func rangeStart(_ value: String) -> Int64? {
        guard let span = value.split(separator: " ").last,
              let start = span.split(separator: "-").first else { return nil }
        return Int64(start)
    }
}

// MARK: - 一件ぶん

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case paused
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL?
    let filename: String
    let destination: URL

    // 最初の応答から拾っておくもの。再開の材料になる
    let expectedTotal: Int64             // Content-Length。不明なら -1
    let acceptsRanges: Bool
    let etag: String?
    let lastModified: String?
    let resolvedURL: URL?                // 転送された後の、実際に取りに行く先
    let originalRequest: URLRequest?
    // 検疫の印に刻むもの。タブが先に消えても書けるよう、ここで控える
    let originURL: URL?                  // 引き金になったページ
    let recordsOrigin: Bool              // 私的窓なら false。出所をディスクへ残さない
    // Cookie を引くために控える。中の websiteDataStore は同じ実体なので、
    // 通常窓と私的窓の区別もそのまま保たれる
    fileprivate let configuration: WKWebViewConfiguration?

    @Published var received: Int64 = 0
    @Published var total: Int64 = -1     // 不明なら -1
    @Published var state: State = .running

    // 中止するために本体を握っておく。所有はしない
    fileprivate weak var download: WKDownload?
    // 続きを取りに行っている間はこちら
    fileprivate var downloader: ResumeDownloader?

    private var observers: [NSKeyValueObservation] = []

    // 続きから拾えるか。サーバーが名乗っていなければ一時停止は出さない
    var canPause: Bool {
        acceptsRanges && expectedTotal > 0 && resolvedURL != nil
    }

    init(download: WKDownload, response: URLResponse, destination: URL) {
        let http = response as? HTTPURLResponse

        self.download = download
        self.sourceURL = download.originalRequest?.url
        self.destination = destination
        self.filename = destination.lastPathComponent
        self.expectedTotal = response.expectedContentLength
        self.acceptsRanges = http?.value(forHTTPHeaderField: "Accept-Ranges")?
            .lowercased().contains("bytes") ?? false
        self.etag = http?.value(forHTTPHeaderField: "ETag")
        self.lastModified = http?.value(forHTTPHeaderField: "Last-Modified")
        self.resolvedURL = response.url ?? download.originalRequest?.url
        self.originalRequest = download.originalRequest
        self.configuration = download.webView?.configuration
        let referer = download.originalRequest?.value(forHTTPHeaderField: "Referer")
        self.originURL = referer.flatMap { URL(string: $0) } ?? download.webView?.url
        // 私的窓は記録を残さない約束になっている。印の中身も同じ扱いにする
        self.recordsOrigin = download.webView?
            .configuration.websiteDataStore.isPersistent ?? true
        self.total = response.expectedContentLength

        observe(download)
    }

    // 進捗は WKDownload が持つ Progress をそのまま見る。自前で数える必要はない。
    // fractionCompleted は必ず KVO で流れてくるので、それを合図に
    // 実際のバイト数を読み直す
    private func observe(_ download: WKDownload) {
        observers.removeAll()
        let progress = download.progress
        observers.append(
            progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] p, _ in
                let got = p.completedUnitCount
                let all = p.totalUnitCount
                Task { @MainActor in
                    guard let self else { return }
                    self.received = got
                    // 総量は最初の応答のものを信じる。
                    // 再開を挟むと Progress 側の総量は当てにならない
                    if self.expectedTotal <= 0 { self.total = all }
                }
            }
        )
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(received) / Double(total), 1)
    }

    // 「3.2 MB / 12.0 MB」。総量が不明なら受信量だけ
    var progressText: String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard total > 0 else { return got }
        let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(got) / \(all)"
    }
}

// MARK: - 受け持ち

@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published var isShelfVisible = false
    // 実行中のものがあるか。
    // 項目の中身の変化をそのまま親に流すと、進捗が動くたびに
    // 画面全体が描き直しになる。状態が変わった時だけ更新する
    @Published private(set) var hasActive = false

    private override init() { super.init() }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    private func refreshActive() {
        hasActive = items.contains { $0.state == .running }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }

    // MARK: - 検疫の印

    // 外から降ってきたファイルには com.apple.quarantine を付ける。
    // これが無いと Gatekeeper が一切口を出さず、署名も notarize もされていない
    // 実行ファイルがそのまま起動できてしまう。
    // OS が勝手に付けてくれるものではなく、持ち込んだ側の責任になっている。
    //
    // 完了時だけでなく、一時停止と失敗の時にも付ける。
    // 書き掛けのファイルが印のないまま手元に居座る時間を作らない
    private static func markQuarantine(_ item: DownloadItem) {
        var url = item.destination
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // 既に付いていれば触らない。何度呼ばれても同じ結果になる
        if let current = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]),
           current.quarantineProperties != nil {
            return
        }

        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Skyscraper",
            kLSQuarantineTimeStampKey as String: Date()
        ]
        if let bundleID = Bundle.main.bundleIdentifier {
            props[kLSQuarantineAgentBundleIdentifierKey as String] = bundleID
        }
        // 出所の URL は xattr としてディスクに残り続ける。
        // 私的窓では書かない。印自体は付くので Gatekeeper は同じように働く
        if item.recordsOrigin {
            if let data = item.resolvedURL ?? item.sourceURL {
                props[kLSQuarantineDataURLKey as String] = data
            }
            if let origin = item.originURL {
                props[kLSQuarantineOriginURLKey as String] = origin
            }
        }

        var values = URLResourceValues()
        values.quarantineProperties = props
        do {
            try url.setResourceValues(values)
        } catch {
            print("[DL] quarantine: could not mark \(url.lastPathComponent): "
                  + error.localizedDescription)
        }
    }

    // MARK: - 操作

    func stop(_ item: DownloadItem) {
        let download = item.download
        let downloader = item.downloader
        // 先に印を付ける。止めた後にも失敗の報せが来るので、上書きされないようにする
        item.state = .cancelled
        item.downloader = nil
        refreshActive()

        downloader?.cancel()
        if let download {
            Task { @MainActor in
                _ = await download.cancel()
                // 途中まで書いたファイルは残る。印のないまま放置しない
                Self.markQuarantine(item)
            }
        } else {
            Self.markQuarantine(item)
        }
    }

    // 一時停止。位置は覚えない。次に再開する時、ディスクを見れば分かる
    func pause(_ item: DownloadItem) {
        guard item.state == .running, item.canPause else { return }
        item.state = .paused
        refreshActive()

        if let downloader = item.downloader {
            item.downloader = nil
            downloader.cancel()
            item.received = max(Self.fileSize(item.destination), 0)
            Self.markQuarantine(item)
        } else if let download = item.download {
            Task { @MainActor in
                _ = await download.cancel()
                item.received = max(Self.fileSize(item.destination), 0)
                Self.markQuarantine(item)
            }
        }
    }

    // 再開。実ファイルの末尾から続きを要求する
    func resume(_ item: DownloadItem) {
        guard item.state == .paused else { return }
        guard let url = item.resolvedURL else {
            item.state = .failed(String(localized: "Cannot resume"))
            refreshActive()
            return
        }

        let offset = Self.fileSize(item.destination)
        guard offset >= 0 else {
            item.state = .failed(String(localized: "Cannot resume"))
            refreshActive()
            return
        }
        // もう全部揃っている
        if item.expectedTotal > 0, offset >= item.expectedTotal {
            item.received = offset
            item.state = .finished
            refreshActive()
            return
        }

        item.received = offset
        item.state = .running
        refreshActive()
        print("[DL] resume from \(offset) of \(item.expectedTotal)")

        Task { @MainActor in
            var request = item.originalRequest ?? URLRequest(url: url)
            request.url = url
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            // 途中で中身が差し替わっていたらサーバーは 200 を返す。
            // その時は頭から書き直すので、黙って壊れることはない
            if let tag = item.etag {
                request.setValue(tag, forHTTPHeaderField: "If-Range")
            } else if let modified = item.lastModified {
                request.setValue(modified, forHTTPHeaderField: "If-Range")
            }
            // 圧縮を挟まれるとバイトの位置が合わなくなる
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

            if let store = item.configuration?.websiteDataStore.httpCookieStore {
                let cookies = await Self.allCookies(store)
                if let header = Self.cookieHeader(for: url, from: cookies) {
                    request.setValue(header, forHTTPHeaderField: "Cookie")
                }
            }

            let downloader = ResumeDownloader(
                destination: item.destination,
                offset: offset,
                onProgress: { bytes in
                    Task { @MainActor in item.received = bytes }
                },
                onFinish: { [weak self] error in
                    Task { @MainActor in self?.resumeDidEnd(item, error: error) }
                })
            item.downloader = downloader
            downloader.start(request: request)
        }
    }

    private func resumeDidEnd(_ item: DownloadItem, error: Error?) {
        defer { refreshActive() }
        item.downloader = nil
        // 自分で止めた時もここへ来る。既に印が変わっていれば触らない
        guard item.state == .running else { return }

        let size = Self.fileSize(item.destination)
        item.received = max(size, 0)
        Self.markQuarantine(item)

        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
            print("[DL] resume failed: \(error.localizedDescription)")
            // 続きから拾えるなら、失敗ではなく止まっているだけ扱いにする
            item.state = item.canPause ? .paused : .failed(error.localizedDescription)
            return
        }

        if item.expectedTotal > 0, size != item.expectedTotal {
            // まだ足りない。もう一度続きを取りに行ける
            item.state = .paused
        } else {
            item.state = .finished
        }
    }

    func revealInFinder(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
    }

    func open(_ item: DownloadItem) {
        NSWorkspace.shared.open(item.destination)
    }

    // 棚を閉じるだけ。記録は残るので、ツールバーから開き直せる
    func hideShelf() {
        isShelfVisible = false
    }

    // 終わったものを記録から消す。実行中・一時停止中のものは残す
    func clearFinished() {
        items.removeAll { $0.state != .running && $0.state != .paused }
        refreshActive()
        if items.isEmpty { isShelfVisible = false }
    }

    // MARK: - Cookie

    private static func allCookies(_ store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    // 自前で投げる要求には Cookie が付かない。宛先に合うものだけ選んで載せる
    private static func cookieHeader(for url: URL, from cookies: [HTTPCookie]) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"
        let now = Date()

        let matched = cookies.filter { cookie in
            var domain = cookie.domain.lowercased()
            let domainMatches: Bool
            if domain.hasPrefix(".") {
                domain.removeFirst()
                domainMatches = host == domain || host.hasSuffix("." + domain)
            } else {
                domainMatches = host == domain
            }
            guard domainMatches else { return false }
            guard cookie.path == "/" || path.hasPrefix(cookie.path) else { return false }
            if cookie.isSecure && !isSecure { return false }
            if let expires = cookie.expiresDate, expires < now { return false }
            return true
        }

        guard !matched.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matched)["Cookie"]
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
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

            // 棚に載せるのは保存先が決まってから。
            // 先に載せると、保存パネルを閉じただけで幽霊が残る
            let item = DownloadItem(download: download, response: response, destination: url)
            self.items.append(item)
            self.isShelfVisible = true
            self.refreshActive()

            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        defer { refreshActive() }
        guard let item = item(for: download) else { return }

        let size = Self.fileSize(item.destination)
        item.received = max(size, 0)
        // 手元に渡る前に印を付ける
        Self.markQuarantine(item)
        // 大きさが合わなければ、中身は信用できない。「完了」として渡さない
        if item.expectedTotal > 0, size != item.expectedTotal {
            item.state = .failed(String(localized: "Incomplete file"))
        } else {
            item.state = .finished
        }
    }

    func download(_ download: WKDownload,
                  didFailWithError error: Error,
                  resumeData: Data?) {
        defer { refreshActive() }
        guard let item = item(for: download) else { return }
        // 自分で止めた時も didFailWithError が来る。上書きしない
        guard item.state == .running else { return }

        print("[DL] failed: \(error.localizedDescription)")
        item.received = max(Self.fileSize(item.destination), 0)
        Self.markQuarantine(item)
        // 続きから拾えるなら、失敗ではなく止まっているだけ扱いにする
        if item.canPause {
            item.state = .paused
        } else {
            item.state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 棚（画面上の一覧）

struct DownloadShelf: View {
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.gold)
                Text("Downloads")
                    .font(.system(size: 11, design: .serif))
                    .tracking(2)
                    .foregroundColor(Deco.cream)

                Spacer()

                // 記録から消すのはこちら。実行中のものは残る
                Button { downloads.clearFinished() } label: {
                    Text("Clear")
                        .font(.system(size: 10, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.dimGold)
                }
                .buttonStyle(.plain)

                // × は棚を閉じるだけ。記録は残るので、
                // ツールバーの矢印ボタンからいつでも開き直せる
                Button { downloads.hideShelf() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(Deco.dimGold)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(downloads.items) { item in
                DownloadRow(item: item, downloads: downloads)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Deco.panel2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Deco.faintGold).frame(height: 1)
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Deco.dimGold)
                .frame(width: 12)

            Text(item.filename)
                .font(.system(size: 11, design: .serif))
                .foregroundColor(Deco.cream)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            if item.state == .running || item.state == .paused {
                // 総量が分からない時は満たさず、受信量だけを出す。
                // 止めている間は棒を鈍らせて、動いていないことを見て分かるようにする
                ZStack(alignment: .leading) {
                    Rectangle().fill(Deco.faintGold.opacity(0.4))
                    GeometryReader { geo in
                        Rectangle()
                            .fill(item.state == .paused ? Deco.dimGold : Deco.gold)
                            .frame(width: geo.size.width * item.fraction)
                    }
                }
                .frame(width: 110, height: 3)
            }

            Text(statusText)
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)

            Spacer()

            switch item.state {
            case .running:
                // 続きから拾えないサーバー相手に一時停止は出さない。
                // 押せば必ず途中から戻せる、という約束を守れる時だけ見せる
                if item.canPause {
                    shelfButton("Pause") { downloads.pause(item) }
                }
                shelfButton("Stop") { downloads.stop(item) }
            case .paused:
                shelfButton("Resume") { downloads.resume(item) }
                shelfButton("Stop") { downloads.stop(item) }
            case .finished:
                shelfButton("Open") { downloads.open(item) }
                shelfButton("Show in Finder") { downloads.revealInFinder(item) }
            case .failed, .cancelled:
                EmptyView()
            }
        }
    }

    private var icon: String {
        switch item.state {
        case .running:   return "arrow.down"
        case .paused:    return "pause"
        case .finished:  return "checkmark"
        case .failed:    return "exclamationmark.triangle"
        case .cancelled: return "minus"
        }
    }

    private var statusText: String {
        switch item.state {
        case .running:          return item.progressText
        case .paused:           return String(localized: "Paused") + " / " + item.progressText
        case .finished:         return String(localized: "Completed")
        case .failed(let why):  return why
        case .cancelled:        return String(localized: "Cancelled")
        }
    }

    private func shelfButton(_ title: LocalizedStringKey,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
