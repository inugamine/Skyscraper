//
//  CastAudio.swift
//  Skyscraper
//
//  Skyscraper が鳴らしている音を、画面の無い Cast 端末 (Home Mini など) や
//  スピーカーのグループへ流す。
//
//  ── なぜこうするのか ──
//  YouTube も YouTube Music も、スピーカー向けの受け手を表に出していない
//  (スマホのアプリでもキャスト先に出てこない)。だから曲を「渡す」のではなく、
//  Skyscraper が鳴らした音そのものを「配る」。
//  Chrome がスピーカーへ飛ばす時と同じ Cast Streaming を自前で喋る:
//
//  1. Core Audio のプロセスタップで、WebKit の裏方 (「Skyscraper Graphics and Media」)
//     の音だけを横取りする。タップしている間は Mac のスピーカーは黙る
//  2. AAC (ADTS) に圧縮する
//  3. 端末で Chrome の音声ミラーリングの受け手 (85CDB22F) を起動し、OFFER で
//     形式・暗号の鍵・遅らせる時間 (targetDelay) を伝える (Cast.swift)
//  4. ANSWER で教わった UDP の口へ、AES-CTR で暗号化した RTP を流す。
//     0.5 秒ごとに RTCP の Sender Report で「この RTP の時刻はこの時計の時刻」と知らせる
//
//  ・遅れは 0.4 秒前後で、グループでも揃う (2026-10-17 に Home Mini・Nest Hub・
//    グループで測った)。動画と音がほぼ合う
//  ・ここに至るまでの回り道:
//    Default Media Receiver に Mac の HTTP の URL を渡す形で始めたが、
//    受け手は「600 KB 前後溜まってから鳴らす」作りで、WAV (1.5 Mbps) で 3〜6 秒、
//    AAC (192 kbps) にすると 26 秒も遅れた。しかも 2026-10-17 にグループの配り直しで
//    WAV だけ通らなくなった (Home Mini が黙る)。時刻で鳴らす Cast Streaming に載せ替えて解決
//  ・RTP の形・暗号・RTCP は Chromium の openscreen (cast/streaming) に合わせてある
//  ・受け手が「この包みが来てない」(Cast の RTCP フィードバックの NACK) と言ってきたら送り直す。
//    受け手は抜けた包みを待って固まり、その先 120 フレーム (約 2.5 秒) を超えた包みは捨てる。
//    送り直さないと、Wi-Fi が何かのタイミングで一瞬取りこぼし(?)ただけで音が二度と戻らない
//    (2026-10-19、Nest Hub がグループのまとめ役の時に 25 秒ほどで止まった)
//  ・拾えるのは Skyscraper 全体の音で、タブ一枚ぶんだけを抜き出す手は無い。
//    だから流している間は他のタブを黙らせる (CastController の役目)
//  ・WKWebView の音は Skyscraper 本体ではなく WebKit の裏方プロセスから鳴っている。
//    裏方は名前 (「<アプリ名> Graphics and Media」) で見分ける
//

import AppKit
import AudioToolbox
import AVFoundation
import CommonCrypto
import CoreAudio
import Foundation
import Network
import os
import Security

// MARK: - 音の出どころを探す

enum CastAudioSource {
    // Skyscraper の音を鳴らしている WebKit の裏方 (の Core Audio 上の札) を全部返す。
    //
    // 裏方は Safari やメールのものも同じ com.apple.WebKit.GPU なので、
    // 「<アプリ名> Graphics and Media」という表示名で見分ける。
    // Xcode 版と配布版を同時に動かしていると両方拾うが、それは諦める
    static func webKitProcesses() -> [AudioObjectID] {
        let appName = NSRunningApplication.current.localizedName ?? "Skyscraper"

        return processObjects().filter { object in
            guard bundleID(of: object) == "com.apple.WebKit.GPU",
                  let name = NSRunningApplication(processIdentifier: pid(of: object))?.localizedName
            else { return false }
            return name.hasPrefix(appName + " ")
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func pid(of object: AudioObjectID) -> pid_t {
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = CoreAudioProperty.address(kAudioProcessPropertyPID)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = CoreAudioProperty.address(kAudioProcessPropertyBundleID)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

nonisolated enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

// MARK: - 拾って配る

// Cast Streaming で送る時の取り決め。OFFER (Cast.swift) と RTP の両方で使う
nonisolated struct CastStreamingKeys: Sendable {
    let ssrc: UInt32
    let aesKey: Data       // 16 バイト
    let aesIVMask: Data    // 16 バイト

    static func random() -> CastStreamingKeys {
        func bytes(_ count: Int) -> Data {
            var data = Data(count: count)
            data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            return data
        }
        return CastStreamingKeys(ssrc: UInt32.random(in: 1...0x7FFF_FFFF),
                                 aesKey: bytes(16), aesIVMask: bytes(16))
    }
}

// タップ・AAC への変換・UDP の送り口をひとまとめに持つ。
//
// 音は Core Audio の実時間スレッドから届くので、この型はメインに縛らない
// (nonisolated)。中の状態は queue の上でだけ触る
nonisolated final class CastAudioPipeline: @unchecked Sendable {
    // 実時間スレッドや queue からも書くので、型の中に持つ (メインに縛られない)
    private static let log = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                                    category: "CastAudio")

    // AAC は 1024 フレームで一包み
    static let framesPerPacket = 1024
    static let bitRate = 192_000
    // 受け手に「これだけ遅らせて鳴らせ」と頼む時間。0.4 秒で取りこぼし無く鳴った
    static let targetDelayMilliseconds = 400
    // Chrome と同じ、音声の RTP の種類番号
    static let rtpPayloadType: UInt8 = 127
    // 送り直しは受け持たないので、1 包みに収まらない分は分けて送る。
    // Ethernet の 1500 から IP と UDP の頭を引いた大きさ
    private static let maxPacketSize = 1500 - 20 - 8
    private static let rtpHeaderSize = 12 + 7

    let keys = CastStreamingKeys.random()
    // 受け手が鳴らす時刻の目盛り。AAC にする時の周波数 (tap が 96k なら 48k に落とす)
    private(set) var outputSampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "net.live-on.inugamine.Skyscraper.cast-audio")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // 以下は queue の上でだけ触る
    private var heardSound = false   // 一度でも無音でない音が来たか
    private var converter: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    private var aacFormat: AVAudioFormat?
    private var adtsRateIndex: UInt8 = 3
    private var pending: [Float] = []   // まだ AAC にしていない分 (左右交互)
    private var tapSampleRate: Double = 48_000
    private var capturedFrames: Int64 = 0   // タップから届いたフレームの総数

    private var connection: NWConnection?
    private var reportTimer: DispatchSourceTimer?
    private var frameID: UInt32 = 0
    private var sequenceNumber = UInt16.random(in: 0...UInt16.max)
    private let rtpStart = UInt32.random(in: 0...0x7FFF_FFFF)
    private var packetsSent: UInt32 = 0
    private var octetsSent: UInt32 = 0

    // 送り直し用に取っておく、最近のフレームの包み (queue の上でだけ触る)
    private var history: [UInt32: [Data]] = [:]
    private static let historyLimit: UInt32 = 500   // 約 10 秒ぶん
    private var nackCount = 0
    private var resentCount = 0
    private var loggedNackCount = 0
    private var reportTicks = 0

    // 許可が無いと、タップは動くが中身は全部 0 になる。
    // それを見抜くために、一度でも音が来たかを外から訊けるようにしておく
    var hasCapturedSound: Bool {
        queue.sync { heardSound }
    }

    // 1. タップを張って AAC の変換器を用意する。
    // 周波数が決まるのはここなので、OFFER (Cast.swift) はこの後に送る。
    // 繋がるまでに届いた音は捨てる (Mac はもう黙っている。1 秒ほどの間)
    func prepare(processes: [AudioObjectID]) throws {
        do {
            try startTap(processes: processes)
        } catch {
            stop()
            throw error
        }
    }

    // 2. ANSWER で教わった UDP の口へ繋いで、流し始める。
    // 受け手は Sender Report を一度受け取るまで一切鳴らさないので、最初に一通送っておく
    func connect(host: String, port: UInt16) async throws {
        guard let udpPort = NWEndpoint.Port(rawValue: port) else { throw CastError.unreachable }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: udpPort, using: .udp)
        try await open(connection)

        queue.sync {
            // ここを RTP の時刻の起点にする。数えるのも送るのもここから
            capturedFrames = 0
            pending.removeAll()
            self.connection = connection
            receiveFeedback(on: connection)
            sendSenderReport()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                self?.sendSenderReport()
                self?.logFeedbackIfChanged()
            }
            timer.resume()
            reportTimer = timer
        }
        Self.log.info("streaming to \(host, privacy: .public):\(port)")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        queue.async { [self] in
            reportTimer?.cancel()
            reportTimer = nil
            connection?.cancel()
            connection = nil
            history.removeAll()
        }
    }

    // MARK: UDP

    private func open(_ connection: NWConnection) async throws {
        // 状態の知らせは queue の上で一本道に届くので、一度きりの印は箱で持てば足りる
        let once = EncoderInputFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !once.given else { return }
                switch state {
                case .ready:
                    once.given = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    once.given = true
                    Self.log.error("udp: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: CastError.unreachable)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // RTCP の Sender Report (RFC 3550 の SR を、報告欄なしで)。
    // 「今この瞬間の時計の時刻は、RTP の目盛りでいうとここ」を知らせる。
    // RTP の側は、実際にタップから届いた数から割り出す。
    // こうしておくと、音の機器の時計と Mac の時計が少しずつずれても、受け手が報告ごとに追い付く
    private func sendSenderReport() {
        guard let connection else { return }
        let now = Date().timeIntervalSince1970 + 2_208_988_800   // NTP は 1900 年が起点
        let seconds = UInt32(truncatingIfNeeded: Int64(now))
        let fraction = UInt32(truncatingIfNeeded: Int64((now - floor(now)) * 4_294_967_296))
        let elapsed = Double(capturedFrames) * outputSampleRate / tapSampleRate
        let rtp = rtpStart &+ UInt32(truncatingIfNeeded: Int64(elapsed))

        var packet = Data()
        packet.append(0x80)                 // V=2, 報告欄なし
        packet.append(200)                  // Sender Report
        packet.appendBigEndian(UInt16(6))   // 長さ (32 bit 単位で、自分を除く)
        packet.appendBigEndian(keys.ssrc)
        packet.appendBigEndian(seconds)
        packet.appendBigEndian(fraction)
        packet.appendBigEndian(rtp)
        packet.appendBigEndian(packetsSent)
        packet.appendBigEndian(octetsSent)
        connection.send(content: packet, completion: .idempotent)
    }

    // AAC の一包みを、暗号化して Cast 流の RTP に詰めて送る
    private func sendFrame(_ frame: Data) {
        guard let connection else { return }
        let id = frameID
        frameID &+= 1

        guard let encrypted = encrypt(frame, frameID: id) else { return }
        let rtpTimestamp = rtpStart &+ id &* UInt32(Self.framesPerPacket)

        let chunkSize = Self.maxPacketSize - Self.rtpHeaderSize
        let chunkCount = max(1, (encrypted.count + chunkSize - 1) / chunkSize)
        var packets: [Data] = []
        for index in 0..<chunkCount {
            let start = index * chunkSize
            let end = min(start + chunkSize, encrypted.count)
            let isLast = index == chunkCount - 1

            var packet = Data()
            // RTP の頭
            packet.append(0x80)
            packet.append((isLast ? 0x80 : 0) | Self.rtpPayloadType)
            packet.appendBigEndian(sequenceNumber)
            packet.appendBigEndian(rtpTimestamp)
            packet.appendBigEndian(keys.ssrc)
            // Cast の頭: キーフレーム + 参照フレームあり / フレーム番号 / 何包み目 / 最後の番号 / 参照先
            // 音は一包みごとに独立しているので、どれもキーフレームで、参照先は自分
            packet.append(0x80 | 0x40)
            packet.append(UInt8(truncatingIfNeeded: id))
            packet.appendBigEndian(UInt16(index))
            packet.appendBigEndian(UInt16(chunkCount - 1))
            packet.append(UInt8(truncatingIfNeeded: id))
            packet.append(encrypted[start..<end])

            connection.send(content: packet, completion: .idempotent)
            packets.append(packet)
            sequenceNumber &+= 1
            packetsSent &+= 1
        }
        octetsSent &+= UInt32(truncatingIfNeeded: encrypted.count)

        history[id] = packets
        history[id &- Self.historyLimit] = nil
    }

    // MARK: 受け手からの RTCP

    // 受け手は届いたフレームごとに RTCP を返してくる。読み続けて、NACK に応える
    private func receiveFeedback(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            // 受け取りの知らせは queue の上で届く (connection を queue で動かしているため)
            if let data { self.handleRTCP(data) }
            if self.connection === connection {
                self.receiveFeedback(on: connection)
            }
        }
    }

    // 複数の RTCP が連なった束を一つずつ読み、Cast のフィードバックだけ拾う
    private func handleRTCP(_ data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 4 <= bytes.count {
            let format = bytes[offset] & 0x1F
            let type = bytes[offset + 1]
            let length = ((Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) + 1) * 4
            guard length > 4, offset + length <= bytes.count else { return }
            let body = Array(bytes[(offset + 4)..<(offset + length)])
            // 206 = Payload-specific feedback / 15 = Cast のフィードバック
            if type == 206, format == 15, body.count >= 16, body[8...11].elementsEqual("CAST".utf8) {
                handleCastFeedback(body)
            }
            offset += length
        }
    }

    // [受け手 SSRC 4][送り手 SSRC 4]["CAST" 4][checkpoint 1][件数 1][遅延 2][抜け 4 × 件数]
    // 抜け一件は [フレーム番号の下 8 bit 1][包みの番号 2][続く 8 包みの印 1]。
    // 包みの番号が 0xFFFF なら、そのフレームの包みが全部来ていない
    private func handleCastFeedback(_ body: [UInt8]) {
        let count = Int(body[13])
        for n in 0..<count {
            let base = 16 + 4 * n
            guard base + 4 <= body.count else { return }
            let id = expandFrameID(body[base])
            guard let packets = history[id] else { continue }
            nackCount += 1

            let packetID = Int(body[base + 1]) << 8 | Int(body[base + 2])
            let bitmask = body[base + 3]
            var wanted: [Int]
            if packetID == 0xFFFF {
                wanted = Array(packets.indices)
            } else {
                wanted = [packetID]
                for bit in 0..<8 where bitmask & (1 << bit) != 0 {
                    wanted.append(packetID + bit + 1)
                }
            }
            for index in wanted where packets.indices.contains(index) {
                connection?.send(content: packets[index], completion: .idempotent)
                resentCount += 1
            }
        }
    }

    // 受け手はフレーム番号の下 8 bit しか言わないので、最近送った番号から元の番号を割り出す
    private func expandFrameID(_ lower: UInt8) -> UInt32 {
        let newest = frameID &- 1
        let distance = UInt8(truncatingIfNeeded: newest) &- lower
        return newest &- UInt32(distance)
    }

    // 送り直しが起きていたら、10 秒に一度の割合で記録に残す (タイマーは 0.5 秒おき)
    private func logFeedbackIfChanged() {
        reportTicks += 1
        guard reportTicks % 20 == 0, nackCount != loggedNackCount else { return }
        loggedNackCount = nackCount
        Self.log.info("receiver asked for \(self.nackCount) missing frames, resent \(self.resentCount) packets")
    }

    // AES-128-CTR (CommonCrypto の CTR は常に big endian で数える)。初期値は 16 バイトの 0 の 8〜11 バイト目にフレーム番号を書き、
    // OFFER で渡したマスクと混ぜたもの (openscreen の frame_crypto.cc と同じ)
    private func encrypt(_ data: Data, frameID: UInt32) -> Data? {
        var nonce = [UInt8](repeating: 0, count: 16)
        nonce[8] = UInt8(truncatingIfNeeded: frameID >> 24)
        nonce[9] = UInt8(truncatingIfNeeded: frameID >> 16)
        nonce[10] = UInt8(truncatingIfNeeded: frameID >> 8)
        nonce[11] = UInt8(truncatingIfNeeded: frameID)
        for (i, mask) in keys.aesIVMask.enumerated() { nonce[i] ^= mask }

        var cryptor: CCCryptorRef?
        let created = keys.aesKey.withUnsafeBytes { key in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                    nonce, key.baseAddress, key.count,
                                    nil, 0, 0, 0, &cryptor)
        }
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count,
                                out.baseAddress, out.count, &moved)
            }
        }
        return status == kCCSuccess ? output : nil
    }

    // MARK: タップ

    private func startTap(processes: [AudioObjectID]) throws {
        // 拾っている間は Mac 側を黙らせる。音はスピーカーの方で鳴る
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            Self.log.error("create tap: \(status)")
            throw CastError.noAudio
        }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = CoreAudioProperty.address(kAudioTapPropertyFormat)
        AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        Self.log.info("tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags)")
        try makeEncoder(sampleRate: format.mSampleRate)

        // タップは単独では読めないので、今の出力先を親にした仮の機器に組み込む
        guard let outputUID = Self.defaultOutputUID() else { throw CastError.noAudio }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Skyscraper Cast",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            Self.log.error("create aggregate: \(status)")
            throw CastError.noAudio
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, let proc else {
            Self.log.error("create ioproc: \(status)")
            throw CastError.noAudio
        }
        procID = proc

        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            Self.log.error("start device: \(status)")
            throw CastError.noAudio
        }
    }

    // 実時間スレッドで呼ばれる。ここでは float を左右交互に写すだけにして、
    // 重い AAC への変換は queue に回す
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var samples: [Float] = []

        if list.count >= 2, let left = list[0].mData, let right = list[1].mData {
            // 左右が別々の帯で来る形
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            let l = left.assumingMemoryBound(to: Float.self)
            let r = right.assumingMemoryBound(to: Float.self)
            samples.reserveCapacity(frames * 2)
            for i in 0..<frames {
                samples.append(l[i])
                samples.append(r[i])
            }
        } else if list.count == 1, let data = list[0].mData {
            // 左右が交互に詰まった形 (ステレオに混ぜてあるので 2 ch)
            let count = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                count: count))
        } else {
            return
        }

        let collected = samples
        let loud = collected.contains { $0 != 0 }
        queue.async { [self] in
            if loud { heardSound = true }
            // 繋がる前の音は数えずに捨てる (RTP の時刻を繋がった瞬間から始めるため)
            guard connection != nil else { return }
            capturedFrames += Int64(collected.count / 2)
            pending.append(contentsOf: collected)
            encodePending()
        }
    }

    // MARK: AAC

    private func makeEncoder(sampleRate: Double) throws {
        // ADTS の頭に書く、サンプリング周波数の番号。
        // 44.1k と 48k 以外 (外付けの DAC で 96k など) は、変換器に 48k へ落とさせる
        let indices: [Double: UInt8] = [48_000: 3, 44_100: 4]
        let outputRate = indices[sampleRate] != nil ? sampleRate : 48_000

        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CastError.noAudio
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: outputRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aac = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: pcm, to: aac) else {
            Self.log.error("AAC encoder unavailable for \(sampleRate) Hz")
            throw CastError.noAudio
        }
        converter.bitRate = Self.bitRate

        queue.sync {
            self.pcmFormat = pcm
            self.aacFormat = aac
            self.converter = converter
            self.adtsRateIndex = indices[outputRate] ?? 3
            self.tapSampleRate = sampleRate
            self.outputSampleRate = outputRate
        }
        Self.log.info("encoding AAC \(outputRate) Hz at \(Self.bitRate) bps")
    }

    // 溜まった分から 1024 フレームずつ AAC にして、ADTS の頭を付けて送る
    private func encodePending() {
        guard let converter, let pcmFormat, let aacFormat else { return }
        let samplesPerPacket = Self.framesPerPacket * 2

        while pending.count >= samplesPerPacket {
            guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                               frameCapacity: AVAudioFrameCount(Self.framesPerPacket)),
                  let channels = input.floatChannelData else { return }
            input.frameLength = AVAudioFrameCount(Self.framesPerPacket)
            for i in 0..<Self.framesPerPacket {
                channels[0][i] = pending[2 * i]
                channels[1][i] = pending[2 * i + 1]
            }
            pending.removeFirst(samplesPerPacket)

            let output = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)

            // 変換器はこの中で入力を引きに来る。一包みだけ渡して、あとは「今は無い」と返す。
            // 変換器は足りない分を覚えておき、次に渡した時に続きから作る
            let once = EncoderInputFlag()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if once.given {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                once.given = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                Self.log.error("AAC encode: \(String(describing: error), privacy: .public)")
                continue
            }

            guard let descriptions = output.packetDescriptions else { continue }
            for index in 0..<Int(output.packetCount) {
                let packet = descriptions[index]
                let payload = Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)),
                                   count: Int(packet.mDataByteSize))
                var frame = adtsHeader(payloadLength: payload.count)
                frame.append(payload)
                sendFrame(frame)
            }
        }
    }

    // ADTS の頭 (7 バイト、CRC 無し)。
    // 受け手は頭を外した生の AAC でも鳴ったが、形式を自分で名乗る分こちらが確か
    private func adtsHeader(payloadLength: Int) -> Data {
        let length = payloadLength + 7
        let profile: UInt8 = 1          // AAC LC (object type 2) - 1
        let channels: UInt8 = 2
        return Data([
            0xFF,
            0xF1,                       // MPEG-4, layer 0, CRC 無し
            (profile << 6) | (adtsRateIndex << 2) | (channels >> 2),
            ((channels & 3) << 6) | UInt8((length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x07) << 5) | 0x1F,
            0xFC,
        ])
    }

    private static func defaultOutputUID() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr else { return nil }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

// 一度きりの印。
// 変換器が入力を引く閉包や、状態の知らせの閉包は呼ばれる度に同じ箱を見るので、
// var を閉包に抱えさせずに箱で持つ
nonisolated private final class EncoderInputFlag: @unchecked Sendable {
    var given = false
}

nonisolated private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        // Data の中では withUnsafeBytes が Data 自身のメソッドを指してしまうので、
        // Swift の大域関数の方だと名指しする
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
