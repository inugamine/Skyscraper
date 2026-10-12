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
//  Chrome がスピーカーへ飛ばす時も同じ発想で、あちらは Cast Streaming
//  (暗号化した RTP) を喋っているが、ここではもっと素直な道を取る:
//
//  1. Core Audio のプロセスタップで、WebKit の裏方 (「Skyscraper Graphics and Media」)
//     の音だけを横取りする。タップしている間は Mac のスピーカーは黙る
//  2. 16 bit の WAV にして、Mac の中に立てた小さな HTTP の口から生配信する
//  3. 端末では Cast 標準の受け手 (Default Media Receiver) にその URL を渡す
//
//  ・遅れは単体で 6 秒前後、グループで 3 秒前後 (2026-10 に測った)。
//    音楽を流す用で、Mac で動画を観ながら音だけ飛ばすのには向かない
//  ・拾えるのは Skyscraper 全体の音で、タブ一枚ぶんだけを抜き出す手は無い。
//    だから流している間は他のタブを黙らせる (CastController の役目)
//  ・WKWebView の音は Skyscraper 本体ではなく WebKit の裏方プロセスから鳴っている。
//    裏方は名前 (「<アプリ名> Graphics and Media」) で見分ける
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Network
import os

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

// タップ・仮の機器・HTTP の口をひとまとめに持つ。
//
// 音は Core Audio の実時間スレッドから届くので、この型はメインに縛らない
// (nonisolated)。中の状態は queue の上でだけ触る
nonisolated final class CastAudioPipeline: @unchecked Sendable {
    // 実時間スレッドや queue からも書くので、型の中に持つ (メインに縛られない)
    private static let log = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                                    category: "CastAudio")

    // URL の道に混ぜる合言葉。LAN の他の誰かが勝手に聴けないように
    let path = "/" + UUID().uuidString.lowercased() + ".wav"

    private let queue = DispatchQueue(label: "net.live-on.inugamine.Skyscraper.cast-audio")

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private var sampleRate: UInt32 = 48_000
    private var heardSound = false   // 一度でも無音でない音が来たか (queue の上で触る)

    // 許可が無いと、タップは動くが中身は全部 0 になる。
    // それを見抜くために、一度でも音が来たかを外から訊けるようにしておく
    var hasCapturedSound: Bool {
        queue.sync { heardSound }
    }

    // タップを張り、HTTP の口を開けて、その番号を返す
    func start(processes: [AudioObjectID]) async throws -> UInt16 {
        try startTap(processes: processes)
        do {
            return try await startListener()
        } catch {
            stop()
            throw error
        }
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
            listener?.cancel()
            listener = nil
            for connection in clients.values { connection.cancel() }
            clients.removeAll()
        }
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
        sampleRate = UInt32(format.mSampleRate)
        Self.log.info("tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags)")

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

    // 実時間スレッドで呼ばれる。float を 16 bit の左右交互に詰め替えて配る
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var pcm = Data()
        var loud = false

        func sample(_ value: Float) -> Int16 {
            if value != 0 { loud = true }
            return Int16(max(-1, min(1, value)) * Float(Int16.max))
        }

        if list.count >= 2, let left = list[0].mData, let right = list[1].mData {
            // 左右が別々の帯で来る形
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            let l = left.assumingMemoryBound(to: Float.self)
            let r = right.assumingMemoryBound(to: Float.self)
            pcm.reserveCapacity(frames * 4)
            for i in 0..<frames {
                withUnsafeBytes(of: sample(l[i]).littleEndian) { pcm.append(contentsOf: $0) }
                withUnsafeBytes(of: sample(r[i]).littleEndian) { pcm.append(contentsOf: $0) }
            }
        } else if list.count == 1, let data = list[0].mData {
            // 左右が交互に詰まった形 (ステレオに混ぜてあるので 2 ch)
            let count = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            let f = data.assumingMemoryBound(to: Float.self)
            pcm.reserveCapacity(count * 2)
            for i in 0..<count {
                withUnsafeBytes(of: sample(f[i]).littleEndian) { pcm.append(contentsOf: $0) }
            }
        } else {
            return
        }

        let payload = pcm
        let wasLoud = loud
        queue.async { [self] in
            if wasLoud { heardSound = true }
            for (id, connection) in clients {
                connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard error != nil, let self else { return }
                    self.queue.async { self.clients[id] = nil }
                })
            }
        }
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

    // MARK: HTTP の口

    // 番号は OS に任せる。開いたら番号を返す
    private func startListener() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        // 状態の知らせは queue の上で一本道に届くので、一度きりの印は箱で持てば足りる
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    once.done = true
                    Self.log.error("listener: \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: CastError.noAudio)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    // 頼みの一行目だけ読んで、合言葉が合えば WAV を流し始める
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, String(parts[1]) == self.path else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            Self.log.info("receiver connected: \(String(describing: connection.endpoint), privacy: .public)")

            // 長さの分からない生配信なので、Content-Length は付けずに閉じるまで流す
            var head = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)
            if parts[0] == "HEAD" {
                connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            head.append(self.wavHeader())
            connection.send(content: head, completion: .contentProcessed { _ in })
            self.clients[ObjectIdentifier(connection)] = connection
        }
    }

    // 大きさを目一杯にした WAV の頭。受け手は終わりを気にせず読み続ける
    private func wavHeader() -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let channels: UInt16 = 2, bits: UInt16 = 16
        data.append(contentsOf: "RIFF".utf8); u32(0xFFFF_FFFF - 8); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * UInt32(channels) * UInt32(bits / 8)); u16(channels * bits / 8); u16(bits)
        data.append(contentsOf: "data".utf8); u32(0xFFFF_FFFF - 44)
        return data
    }
}
