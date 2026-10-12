//
//  Cast.swift
//  Skyscraper
//
//  YouTube の動画を、家の Google Cast 端末 (Nest Hub など) へ飛ばす。
//
//  ── なぜ自前で喋るのか ──
//  YouTube のキャストボタンは Chrome に組み込まれた Cast の送り手に頼っていて、
//  WKWebView には同じものが無い。macOS 向けの公式 SDK も無い。
//  だから Cast の手順を自分で喋る。やり取りするのは数種類の文だけなので、
//  protobuf のライブラリは入れずに手で組む (Punycode の時と同じ考え)。
//
//  ── 流れ ──
//  1. Bonjour で _googlecast._tcp を探す。TXT の ca (能力の印) で
//     画面のある端末だけを残す。スピーカーとグループは出さない
//  2. 端末の 8009 番へ TLS で繋ぎ、受け手の YouTube アプリ (233637DE) を起動する
//  3. YouTube アプリに getMdxSessionStatus を訊いて screenId をもらう
//  4. ここから先は YouTube の lounge API (HTTP)。
//     screenId → loungeToken → bind (SID と gsessionid) → setPlaylist で再生が始まる
//
//     位置はタブで観ていた所から (setPlaylist の currentTime)
//  5. 再生が始まったら繋がりは切らずに持っておき、Cast の標準の media の口で
//     一時停止・シーク・停止を送る。状態 (題・位置・長さ) は MEDIA_STATUS で届く
//
//  4 は非公式の口なので、Google の都合でいつ壊れても文句は言えない。
//  壊れたら Console.app で category "Cast" を見ること。
//
//  再生は端末の YouTube アプリが自分で動画を取りに行く。
//  画面の写し (ミラーリング) ではないし、誰のアカウントでもない
//  (2026-10 に試した時、履歴には残らなかった)。
//

import Combine
import Foundation
import Network
import SwiftUI
import WebKit
import os

// MARK: - 記録

private let castLog = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                             category: "Cast")

// MARK: - URL から動画 ID を拾う

enum YouTubeVideoID {
    // youtube.com/watch?v=ID・youtu.be/ID・/shorts/ID・/live/ID・/embed/ID。
    // 動画 ID は英数字と - _ の 11 文字。形の合わないものは拾わない
    static func from(_ urlText: String) -> String? {
        guard let components = URLComponents(string: urlText),
              let host = components.host?.lowercased() else { return nil }

        let parts = components.path.split(separator: "/").map(String.init)
        var candidate: String?

        if host == "youtu.be" {
            candidate = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if components.path == "/watch" {
                candidate = components.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) {
                candidate = parts[1]
            }
        }

        guard let id = candidate, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }
}

// MARK: - 端末

struct CastDevice: Identifiable, Hashable {
    let id: String          // TXT の id。無ければサービス名
    let name: String        // TXT の fn (Home アプリでの名前)
    let model: String       // TXT の md
    let endpoint: NWEndpoint
}

// MARK: - 端末を探す

@MainActor
final class CastDiscovery: ObservableObject {
    static let shared = CastDiscovery()

    @Published private(set) var devices: [CastDevice] = []
    // ローカルネットワークの許可が無い時に立つ。
    // 設定で許可されれば、NWBrowser が自分で立ち直って .ready に戻る
    @Published private(set) var isDenied = false

    private var browser: NWBrowser?

    // GCKDeviceCapability の印 (Google の iOS SDK の定義)
    private static let videoOut = 1 << 0
    private static let multizoneGroup = 1 << 5

    // kDNSServiceErr_PolicyDenied。ローカルネットワークの許可が無い時に返る
    private static let policyDenied: Int32 = -65570

    private init() {}

    // 初めてキャストの盤を開いた時に呼ばれる。
    // 起動時に探し始めないのは、YouTube を見ない人にまで
    // ローカルネットワークの許可を訊かないため。
    // 一度始めたら走らせたままにする (Bonjour の見張りは軽い)
    func start() {
        guard browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: "local."),
            using: NWParameters()
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            MainActor.assumeIsolated { self.handle(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.apply(results) }
        }
        // 返事はメインへ。だから上の assumeIsolated が通る
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isDenied = false
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == Self.policyDenied {
                isDenied = true
            }
            castLog.error("browser: \(String(describing: error), privacy: .public)")
            if case .failed = state {
                self.browser?.cancel()
                self.browser = nil
            }
        default:
            break
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        // 同じ端末が Wi-Fi と有線の両方から見えることがあるので、id で束ねる
        var found: [String: CastDevice] = [:]

        for result in results {
            guard case .service(let serviceName, _, _, _) = result.endpoint else { continue }

            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            let name = txt["fn"] ?? serviceName
            let model = txt["md"] ?? ""
            let capabilities = Int(txt["ca"] ?? "") ?? 0

            castLog.debug("found \(name, privacy: .public) (\(model, privacy: .public)) ca=\(capabilities)")

            // 画面のある端末だけ。
            // Home Mini (ca=2052) は音だけ、グループは複数のスピーカーを束ねた仮の端末で、
            // どちらも YouTube の動画アプリが居つかない (2026-10 に試して確かめた)
            guard capabilities & Self.videoOut != 0,
                  capabilities & Self.multizoneGroup == 0 else { continue }

            let id = txt["id"] ?? serviceName
            found[id] = CastDevice(id: id, name: name, model: model, endpoint: result.endpoint)
        }

        devices = found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - 再生を頼む窓口・飛ばした後の操作

@MainActor
final class CastController: ObservableObject {
    static let shared = CastController()

    enum PlayerState: String {
        case playing = "PLAYING"
        case paused = "PAUSED"
        case buffering = "BUFFERING"
        case idle = "IDLE"
    }

    // 端末で今流れているもの。
    // 再生位置は「updatedAt の時点で position 秒」とだけ持ち、
    // 間の秒数は画面側で足して進める (端末は状態が変わった時しか知らせてこない)
    struct NowPlaying {
        let device: CastDevice
        var mediaSessionID: Int?
        var title: String?
        var state: PlayerState = .buffering
        var position: Double = 0
        var duration: Double?
        var updatedAt = Date()

        func position(at date: Date) -> Double {
            var value = position
            if state == .playing {
                value += date.timeIntervalSince(updatedAt)
            }
            if let duration { value = min(value, duration) }
            return max(0, value)
        }
    }

    // 今つなぎに行っている端末。二重に押されないための見張りも兼ねる
    @Published private(set) var connectingDeviceID: String?
    @Published var lastError: String?
    // 飛ばしている間だけ立つ。これがある間、📺 はどのタブにも出る
    @Published private(set) var nowPlaying: NowPlaying?

    private var link: CastLink?
    private var nextRequestID = 1000

    private init() {}

    // 成功したら true。失敗の文言は lastError に置く
    // startTime は秒。タブで観ていた所から続けるのに使う
    func play(videoID: String, startTime: Double = 0, on device: CastDevice) async -> Bool {
        guard connectingDeviceID == nil else { return false }
        connectingDeviceID = device.id
        lastError = nil
        defer { connectingDeviceID = nil }

        // 前の端末との繋がりは切る。向こうの再生はそのまま続く
        end()

        do {
            let link = try await CastSession.playYouTube(videoID, startTime: startTime, on: device)
            castLog.info("playing \(videoID, privacy: .public) at \(Int(startTime))s on \(device.name, privacy: .public)")
            adopt(link, device: device, startTime: startTime)
            return true
        } catch {
            castLog.error("cast failed: \(String(describing: error), privacy: .public)")
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: 操作

    var canControl: Bool { nowPlaying?.mediaSessionID != nil }

    func togglePlayPause() {
        guard let now = nowPlaying else { return }
        let pausing = now.state == .playing || now.state == .buffering
        sendMedia(pausing ? "PAUSE" : "PLAY")
        // 返事を待たずに印を変える。本当の状態は MEDIA_STATUS で上書きされる
        nowPlaying?.position = now.position(at: .now)
        nowPlaying?.updatedAt = .now
        nowPlaying?.state = pausing ? .paused : .playing
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        sendMedia("SEEK", ["currentTime": target])
        nowPlaying?.position = target
        nowPlaying?.updatedAt = .now
    }

    func skip(by delta: Double) {
        guard let now = nowPlaying else { return }
        seek(to: now.position(at: .now) + delta)
    }

    // 端末の YouTube を閉じて、Hub を元の画面に戻す
    func stop() {
        if let link {
            link.channel.send(CastNamespace.receiver, to: CastSession.platform, [
                "type": "STOP",
                "sessionId": link.sessionID,
                "requestId": requestID(),
            ])
        }
        end()
    }

    // MARK: 内側

    private func adopt(_ link: CastLink, device: CastDevice, startTime: Double) {
        self.link = link
        // 最初の MEDIA_STATUS が届くまでは、頼んだ位置を仮に出しておく
        nowPlaying = NowPlaying(device: device, position: startTime)

        link.channel.onMessage = { [weak self, weak link] message, json in
            guard let self, let link, link === self.link else { return }
            self.handle(message, json, from: link)
        }
        link.channel.onClose = { [weak self, weak link] in
            guard let self, let link, link === self.link else { return }
            castLog.info("link closed")
            self.end()
        }

        // こちらからも 5 秒おきに PING を打つ。黙っていると端末に切られる
        link.heartbeat = Task { [weak link] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                link?.channel.send(CastNamespace.heartbeat, to: CastSession.platform, ["type": "PING"])
            }
        }

        // mediaSessionId を手に入れるまでは操作できない。
        // 読み込み中は答えが空のことがあるので、間を空けて二度訊く
        sendGetStatus()
        Task { [weak self, weak link] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let link, link === self.link,
                  self.nowPlaying?.mediaSessionID == nil else { return }
            self.sendGetStatus()
        }
    }

    // 繋がりを捨てる。端末の再生には触らない
    private func end() {
        guard let link else { return }
        self.link = nil
        link.heartbeat?.cancel()
        link.channel.onMessage = nil
        link.channel.onClose = nil
        link.channel.close()
        nowPlaying = nil
    }

    private func handle(_ message: CastMessage, _ json: [String: Any], from link: CastLink) {
        switch (message.namespace, json["type"] as? String) {
        case (CastNamespace.media, "MEDIA_STATUS"?):
            guard let statuses = json["status"] as? [[String: Any]],
                  let status = statuses.first else { return }
            apply(status)

        case (CastNamespace.receiver, "RECEIVER_STATUS"?):
            // YouTube が居なくなった (Hub 側で止められた・別の送り手に取られた)
            if CastSession.youTubeApp(in: json)?["transportId"] as? String != link.transportID {
                castLog.info("YouTube left the device")
                end()
            }

        default:
            break
        }
    }

    private func apply(_ status: [String: Any]) {
        guard var now = nowPlaying else { return }

        // 自動再生で次の動画に移ると番号が変わる。前の題と長さは捨てる
        if let id = status["mediaSessionId"] as? Int, id != now.mediaSessionID {
            if now.mediaSessionID != nil {
                now.title = nil
                now.duration = nil
            }
            now.mediaSessionID = id
        }
        if let raw = status["playerState"] as? String, let state = PlayerState(rawValue: raw) {
            now.state = state
        }
        if let time = status["currentTime"] as? Double {
            now.position = time
            now.updatedAt = .now
        }
        if let media = status["media"] as? [String: Any] {
            if let duration = media["duration"] as? Double, duration > 0 {
                now.duration = duration
            }
            if let metadata = media["metadata"] as? [String: Any],
               let title = metadata["title"] as? String, !title.isEmpty {
                now.title = title
            }
        }
        nowPlaying = now
    }

    private func sendMedia(_ type: String, _ extra: [String: Any] = [:]) {
        guard let link, let id = nowPlaying?.mediaSessionID else { return }
        var payload: [String: Any] = ["type": type, "mediaSessionId": id, "requestId": requestID()]
        payload.merge(extra) { _, new in new }
        link.channel.send(CastNamespace.media, to: link.transportID, payload)
    }

    private func sendGetStatus() {
        guard let link else { return }
        link.channel.send(CastNamespace.media, to: link.transportID,
                          ["type": "GET_STATUS", "requestId": requestID()])
    }

    private func requestID() -> Int {
        nextRequestID += 1
        return nextRequestID
    }
}

// 端末との繋がり一本と、そこで起動した YouTube の札
@MainActor
private final class CastLink {
    let channel: CastChannel
    let transportID: String
    let sessionID: String
    var heartbeat: Task<Void, Never>?

    init(channel: CastChannel, transportID: String, sessionID: String) {
        self.channel = channel
        self.transportID = transportID
        self.sessionID = sessionID
    }
}

// MARK: - 失敗の種類

enum CastError: LocalizedError {
    case unreachable
    case timeout
    case closed
    case launchFailed
    case lounge

    var errorDescription: String? {
        switch self {
        case .unreachable:  String(localized: "Couldn’t reach the device.")
        case .timeout:      String(localized: "The device didn’t answer in time.")
        case .closed:       String(localized: "The connection to the device was closed.")
        case .launchFailed: String(localized: "YouTube couldn’t start on the device.")
        case .lounge:       String(localized: "YouTube didn’t accept the request.")
        }
    }
}

// MARK: - 一回ぶんの手順

private enum CastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat  = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver   = "urn:x-cast:com.google.cast.receiver"
    static let media      = "urn:x-cast:com.google.cast.media"
    static let mdx        = "urn:x-cast:com.google.youtube.mdx"
}

private enum CastSession {
    static let youTubeAppID = "233637DE"
    static let platform = "receiver-0"

    // 再生まで漕ぎ着けたら、繋がりを開いたまま返す。
    // 以後の操作 (一時停止・シーク・停止) はこの繋がりの上で送る
    static func playYouTube(_ videoID: String, startTime: Double,
                            on device: CastDevice) async throws -> CastLink {
        let channel = CastChannel(endpoint: device.endpoint)
        do {
            try await channel.open()

            // 1. 端末そのものに挨拶して、YouTube アプリを起動する
            channel.send(CastNamespace.connection, to: platform, ["type": "CONNECT"])
            channel.send(CastNamespace.receiver, to: platform, [
                "type": "LAUNCH",
                "appId": youTubeAppID,
                "requestId": channel.nextRequestID(),
            ])

            // 起動前の様子が先に届くことがあるので、YouTube の transportId が
            // 載った RECEIVER_STATUS が来るまで待つ
            let launched = try await channel.wait(timeout: .seconds(20)) { message, json in
                message.namespace == CastNamespace.receiver
                    && (json["type"] as? String == "LAUNCH_ERROR"
                        || CastSession.youTubeApp(in: json)?["transportId"] != nil)
            }
            guard let app = youTubeApp(in: launched.json),
                  let transport = app["transportId"] as? String else {
                throw CastError.launchFailed
            }
            let sessionID = app["sessionId"] as? String ?? ""

            // 2. 起動した YouTube アプリに繋ぎ、screenId を訊く。
            // 起動直後は返事をしないことがあるので、答えるまで数回訊き直す
            channel.send(CastNamespace.connection, to: transport, ["type": "CONNECT"])
            let asking = Task {
                for _ in 0..<5 {
                    channel.send(CastNamespace.mdx, to: transport, ["type": "getMdxSessionStatus"])
                    try await Task.sleep(for: .seconds(3))
                }
            }
            defer { asking.cancel() }

            let status = try await channel.wait(timeout: .seconds(15)) { message, json in
                message.namespace == CastNamespace.mdx
                    && json["type"] as? String == "mdxSessionStatus"
            }
            guard let data = status.json["data"] as? [String: Any],
                  let screenID = data["screenId"] as? String else {
                throw CastError.launchFailed
            }

            // 3. ここから先は HTTP
            try await YouTubeLounge.play(videoID: videoID, startTime: startTime, screenID: screenID)

            return CastLink(channel: channel, transportID: transport, sessionID: sessionID)
        } catch {
            channel.close()
            throw error
        }
    }

    // RECEIVER_STATUS の中から YouTube アプリの札を探す
    static func youTubeApp(in json: [String: Any]) -> [String: Any]? {
        guard let status = json["status"] as? [String: Any],
              let apps = status["applications"] as? [[String: Any]] else { return nil }
        return apps.first { $0["appId"] as? String == youTubeAppID }
    }
}

// MARK: - 端末との通り道

// Cast の文は「4 バイトの長さ (big endian)」+「protobuf の CastMessage」。
// NWConnection はメインのキューで動かすので、返事は全てメインに届く
@MainActor
private final class CastChannel {
    private struct Waiter {
        let match: (CastMessage, [String: Any]) -> Bool
        let continuation: CheckedContinuation<CastMessage, Error>
    }

    private let connection: NWConnection
    private var buffer = Data()
    private var waiters: [UUID: Waiter] = [:]
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var requestID = 0

    // 待ち人のいない文も含めて、届いた文を全部聞く者。
    // 飛ばした後の操作盤 (CastController) が MEDIA_STATUS を拾うのに使う
    var onMessage: ((CastMessage, [String: Any]) -> Void)?
    // 繋がりが切れた時に一度だけ呼ばれる。こちらから close() した時も呼ばれるので、
    // 要らなければ先に nil にしておくこと
    var onClose: (() -> Void)?

    init(endpoint: NWEndpoint) {
        // Cast 端末の証明書は端末ごとの自己署名なので、検証は通す。
        // 本家の送り手は deviceauth で端末の真偽を確かめるが、ここでは省く。
        // 渡すのは動画 ID だけで、家の中の相手なので、偽物に掴まされても失うものが無い
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .main)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8

        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                MainActor.assumeIsolated { self.handle(state) }
            }
            connection.start(queue: .main)
        }
    }

    func close() {
        connection.cancel()
    }

    func nextRequestID() -> Int {
        requestID += 1
        return requestID
    }

    func send(_ namespace: String, to destination: String, _ payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }

        let body = CastMessage(source: "sender-0", destination: destination,
                               namespace: namespace, payload: text).encoded()
        var frame = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)

        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // 条件に合う文が届くまで待つ。届かなければ timeout で投げる
    func wait(timeout: Duration,
              _ match: @escaping (CastMessage, [String: Any]) -> Bool) async throws -> CastMessage {
        if let failure { throw failure }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = Waiter(match: match, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(id)
            }
        }
    }

    // MARK: 内側

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if let continuation = openContinuation {
                openContinuation = nil
                continuation.resume()
            }
            receive()
        case .waiting(let error):
            // 繋がる見込みが無い (許可が無い・相手がいない)。粘らずに諦める
            castLog.error("connection waiting: \(String(describing: error), privacy: .public)")
            fail(CastError.unreachable)
            connection.cancel()
        case .failed(let error):
            castLog.error("connection failed: \(String(describing: error), privacy: .public)")
            fail(CastError.unreachable)
        case .cancelled:
            fail(CastError.closed)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let data {
                    self.buffer.append(data)
                    self.drain()
                }
                if error != nil || isComplete {
                    self.fail(CastError.closed)
                    return
                }
                self.receive()
            }
        }
    }

    // 溜まった分から、丸ごと届いた文を一つずつ切り出す
    private func drain() {
        while buffer.count >= 4 {
            let head = [UInt8](buffer.prefix(4))
            let length = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
            guard buffer.count >= 4 + length else { return }

            let start = buffer.startIndex
            let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
            buffer = Data(buffer.dropFirst(4 + length))

            if let message = CastMessage(decoding: body) {
                dispatch(message)
            }
        }
    }

    private func dispatch(_ message: CastMessage) {
        let json = message.json

        // 端末は数秒おきに PING を寄越す。返さないと切られる
        if message.namespace == CastNamespace.heartbeat, json["type"] as? String == "PING" {
            send(CastNamespace.heartbeat, to: message.source, ["type": "PONG"])
            return
        }

        castLog.debug("← \(message.namespace, privacy: .public) \(json["type"] as? String ?? "?", privacy: .public)")

        for (id, waiter) in waiters where waiter.match(message, json) {
            waiters[id] = nil
            waiter.continuation.resume(returning: message)
        }
        onMessage?(message, json)
    }

    private func expire(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CastError.timeout)
    }

    // 以後の wait も含めて、待っている者を全員この失敗で帰す
    private func fail(_ error: Error) {
        if failure == nil { failure = error }

        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(throwing: error)
        }
        let pending = waiters
        waiters = [:]
        for waiter in pending.values {
            waiter.continuation.resume(throwing: error)
        }

        if let onClose {
            self.onClose = nil
            onClose()
        }
    }
}

// MARK: - protobuf の CastMessage

// cast_channel.proto の CastMessage のうち、使う欄だけ。
//   1 protocol_version (enum)  常に 0 (CASTV2_1_0)
//   2 source_id (string)
//   3 destination_id (string)
//   4 namespace (string)
//   5 payload_type (enum)      常に 0 (STRING)
//   6 payload_utf8 (string)
// 7 番の payload_binary は deviceauth でしか使わないので読み捨てる
private struct CastMessage {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
    }

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data()
        data.appendVarintField(1, 0)
        data.appendStringField(2, source)
        data.appendStringField(3, destination)
        data.appendStringField(4, namespace)
        data.appendVarintField(5, 0)
        data.appendStringField(6, payload)
        return data
    }

    // 形が崩れていたら nil
    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Int: String] = [:]

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        while index < bytes.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3)

            switch key & 0x07 {
            case 0:     // varint
                guard readVarint() != nil else { return nil }
            case 1:     // 64 bit
                index += 8
            case 2:     // 長さ付き
                guard let length = readVarint(), index + Int(length) <= bytes.count else { return nil }
                let end = index + Int(length)
                if (2...6).contains(field) {
                    fields[field] = String(decoding: bytes[index..<end], as: UTF8.self)
                }
                index = end
            case 5:     // 32 bit
                index += 4
            default:
                return nil
            }
        }
        guard index == bytes.count else { return nil }

        self.init(source: fields[2] ?? "", destination: fields[3] ?? "",
                  namespace: fields[4] ?? "", payload: fields[6] ?? "")
    }
}

private extension Data {
    mutating func appendVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }

    mutating func appendVarintField(_ field: Int, _ value: UInt64) {
        appendVarint(UInt64(field << 3 | 0))
        appendVarint(value)
    }

    mutating func appendStringField(_ field: Int, _ string: String) {
        let bytes = Data(string.utf8)
        appendVarint(UInt64(field << 3 | 2))
        appendVarint(UInt64(bytes.count))
        append(bytes)
    }
}

// MARK: - YouTube の lounge API

// casttube (Python) と同じ手順。
// 送り手を名乗る値 (app の文字列など) も casttube に合わせてある——
// 変えると YouTube 側に弾かれるかもしれないので、動いている形を崩さない
private enum YouTubeLounge {
    private static let base = "https://www.youtube.com/api/lounge/"

    // クッキーを持たない使い捨ての通り道。
    // ブラウザのログイン状態を YouTube の裏口へ流さない
    private static let session = URLSession(configuration: .ephemeral)

    // 送り手の名札。casttube は "a" を 26 個並べている。起動ごとに一つ作る
    private static let remoteID: String = {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<26).map { _ in letters.randomElement()! })
    }()

    static func play(videoID: String, startTime: Double, screenID: String) async throws {
        // screenId → loungeToken
        let tokenReply = try await post("pairing/get_lounge_token_batch",
                                        form: [("screen_ids", screenID)])
        guard let object = try? JSONSerialization.jsonObject(with: tokenReply) as? [String: Any],
              let screens = object["screens"] as? [[String: Any]],
              let token = screens.first?["loungeToken"] as? String else {
            throw CastError.lounge
        }

        // bind で SID と gsessionid をもらう。
        // 返事は JSON ではなく独自の束なので、目印の後ろを切り出す
        let bindReply = try await post(
            "bc/bind",
            query: [("RID", "0"), ("VER", "8"), ("CVER", "1")],
            form: [
                ("device", "REMOTE_CONTROL"),
                ("id", remoteID),
                ("name", "Skyscraper"),
                ("mdx-version", "3"),
                ("pairing_type", "cast"),
                ("app", "android-phone-13.14.55"),
            ],
            token: token
        )
        let text = String(decoding: bindReply, as: UTF8.self)
        guard let sid = capture(in: text, after: "\"c\",\""),
              let gsessionID = capture(in: text, after: "\"S\",\"") else {
            castLog.error("bind reply without SID: \(String(text.prefix(200)), privacy: .public)")
            throw CastError.lounge
        }

        // 動画を一本だけの再生列にして、startTime 秒から流す。
        // req0_currentTime は casttube の start_time と同じ欄。整数の秒で渡す
        _ = try await post(
            "bc/bind",
            query: [("SID", sid), ("gsessionid", gsessionID),
                    ("RID", "1"), ("VER", "8"), ("CVER", "1")],
            form: [
                ("count", "1"),
                ("req0__sc", "setPlaylist"),
                ("req0_listId", ""),
                ("req0_currentTime", String(Int(max(0, startTime)))),
                ("req0_currentIndex", "-1"),
                ("req0_audioOnly", "false"),
                ("req0_videoId", videoID),
            ],
            token: token
        )
    }

    private static func post(_ path: String,
                             query: [(String, String)] = [],
                             form: [(String, String)],
                             token: String? = nil) async throws -> Data {
        guard var components = URLComponents(string: base + path) else { throw CastError.lounge }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw CastError.lounge }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Origin")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-YouTube-LoungeId-Token")
        }
        request.httpBody = Data(form.map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            castLog.error("lounge \(path, privacy: .public) → \(code)")
            throw CastError.lounge
        }
        return data
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    // marker の直後から、次の " までを返す
    private static func capture(in text: String, after marker: String) -> String? {
        guard let start = text.range(of: marker)?.upperBound,
              let end = text[start...].firstIndex(of: "\"") else { return nil }
        let value = String(text[start..<end])
        return value.isEmpty ? nil : value
    }
}

// MARK: - アドレスバーのボタン

// YouTube の動画を開いている時と、どこかへ飛ばしている間だけ現れる。
// 飛ばしている間は塗りつぶしの印になり、どのタブからでも操作盤を開ける
struct CastButton: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var controller = CastController.shared
    @State private var showing = false

    var body: some View {
        let casting = controller.nowPlaying != nil
        if casting || YouTubeVideoID.from(tab.urlText) != nil {
            Button {
                showing.toggle()
            } label: {
                Image(systemName: casting ? "tv.fill" : "tv")
                    .font(.system(size: 13))
                    .foregroundColor(casting ? Deco.cream : Deco.gold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(helpText)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                CastPopover(tab: tab)
            }
        }
    }

    private var helpText: Text {
        if let now = controller.nowPlaying {
            Text("Playing on \(now.device.name)")
        } else {
            Text("Play on Device")
        }
    }
}

private struct CastPopover: View {
    @ObservedObject var tab: Tab

    @ObservedObject private var discovery = CastDiscovery.shared
    @ObservedObject private var controller = CastController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let now = controller.nowPlaying {
                NowPlayingPanel(now: now)
            }

            // 動画のページにいる時だけ、端末の一覧も出す (別の動画を飛ばし直せる)
            if YouTubeVideoID.from(tab.urlText) != nil {
                if controller.nowPlaying != nil {
                    Rectangle()
                        .fill(Deco.faintGold)
                        .frame(height: 1)
                }
                deviceList
            }

            if let error = controller.lastError {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundColor(Deco.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 280, alignment: .leading)
        .background(Deco.panel)
        .onAppear {
            controller.lastError = nil
            discovery.start()
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Play on Device")
                .font(.system(size: 13, design: .serif))
                .foregroundColor(Deco.gold)

            if discovery.isDenied {
                Text("Allow Skyscraper to access the local network in System Settings › Privacy & Security.")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.cream)
                    .fixedSize(horizontal: false, vertical: true)
            } else if discovery.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…")
                        .font(.system(size: 12))
                        .foregroundColor(Deco.dimGold)
                }
            } else {
                ForEach(discovery.devices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: CastDevice) -> some View {
        Button {
            cast(to: device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                    .font(.system(size: 12))
                    .foregroundColor(Deco.gold)
                Text(verbatim: device.name)
                    .font(.system(size: 12))
                    .foregroundColor(Deco.cream)
                Spacer(minLength: 0)
                if controller.connectingDeviceID == device.id {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.connectingDeviceID != nil)
        .help(device.model)
    }

    private func cast(to device: CastDevice) {
        // 押した瞬間の URL から拾う。盤を開いた後に動画を移っていてもずれない
        guard let videoID = YouTubeVideoID.from(tab.urlText) else { return }
        Task {
            // 先にタブ側を止めて、止めた位置から端末で続ける。
            // 繋がるまでの数秒、両方から音が出るのを避けるためでもある
            let paused = await pauseTab()
            let ok = await controller.play(videoID: videoID, startTime: paused.time, on: device)
            // 飛ばせなかったら、止める前の様子に戻す
            if !ok && paused.wasPlaying {
                _ = try? await tab.webView.evaluateJavaScript(Self.resumeScript)
            }
            // 盤は閉じない。そのまま上に操作盤が現れる
        }
    }

    // タブの動画を全て止めて、本編の位置と、止める前に流れていたかを返す。
    // 本編は #movie_player の中の video。広告や棚の試写も video なので、そちらは拾わない。
    // 最後まで観終わっている (残り 3 秒未満) なら頭から
    private static let pauseScript = """
        (() => {
          const v = document.querySelector('#movie_player video') || document.querySelector('video');
          const wasPlaying = !!v && !v.paused && !v.ended;
          document.querySelectorAll('video').forEach(x => x.pause());
          if (!v) return [0, false];
          const left = (v.duration || 0) - v.currentTime;
          const time = (v.ended || (v.duration && left < 3)) ? 0 : v.currentTime;
          return [time, wasPlaying];
        })()
        """

    private static let resumeScript = """
        (() => {
          const v = document.querySelector('#movie_player video') || document.querySelector('video');
          if (v) v.play();
          return true;
        })()
        """

    private func pauseTab() async -> (time: Double, wasPlaying: Bool) {
        let result = try? await tab.webView.evaluateJavaScript(Self.pauseScript)
        guard let values = result as? [Any], values.count == 2 else { return (0, false) }
        let time = (values[0] as? NSNumber)?.doubleValue ?? 0
        let wasPlaying = (values[1] as? NSNumber)?.boolValue ?? false
        return (time.isFinite ? time : 0, wasPlaying)
    }
}

// MARK: - 飛ばした後の操作盤

private struct NowPlayingPanel: View {
    let now: CastController.NowPlaying
    @ObservedObject private var controller = CastController.shared

    // 摘みを掴んでいる間の位置。離した時に一度だけ SEEK を送る
    @State private var scrubbing: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playing on \(now.device.name)")
                .font(.system(size: 13, design: .serif))
                .foregroundColor(Deco.gold)

            if let title = now.title {
                Text(verbatim: title)
                    .font(.system(size: 12))
                    .foregroundColor(Deco.cream)
                    .lineLimit(2)
            }

            // 端末は状態が変わった時しか位置を知らせてこないので、
            // 一秒ごとに手元で進めて描く
            TimelineView(.periodic(from: .now, by: 1)) { context in
                timeline(position: scrubbing ?? now.position(at: context.date))
            }

            HStack(spacing: 22) {
                Spacer()
                controlButton("gobackward.10", size: 14, help: "Back 10 Seconds") {
                    controller.skip(by: -10)
                }
                controlButton(isPlaying ? "pause.fill" : "play.fill", size: 18,
                              help: isPlaying ? "Pause" : "Play") {
                    controller.togglePlayPause()
                }
                controlButton("goforward.10", size: 14, help: "Forward 10 Seconds") {
                    controller.skip(by: 10)
                }
                Spacer()
            }
            .disabled(!controller.canControl)
            .opacity(controller.canControl ? 1 : 0.4)

            Button {
                controller.stop()
            } label: {
                Label("Stop Casting", systemImage: "stop.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.dimGold)
            }
            .buttonStyle(.plain)
        }
    }

    private var isPlaying: Bool {
        now.state == .playing || now.state == .buffering
    }

    @ViewBuilder
    private func timeline(position: Double) -> some View {
        VStack(spacing: 2) {
            // 生配信は長さが無いので、摘みは出さない (±10 秒は効く)
            if let duration = now.duration {
                Slider(
                    value: Binding(
                        get: { min(position, duration) },
                        set: { scrubbing = $0 }
                    ),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            controller.seek(to: target)
                            scrubbing = nil
                        }
                    }
                )
                .controlSize(.small)
                .tint(Deco.gold)
                .disabled(!controller.canControl)
            }
            HStack {
                Text(verbatim: Self.clock(position))
                Spacer()
                if let duration = now.duration {
                    Text(verbatim: Self.clock(duration))
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(Deco.dimGold)
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat,
                               help: LocalizedStringKey,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(Deco.gold)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // 1:05 / 1:02:03
    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
