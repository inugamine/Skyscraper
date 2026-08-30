//
//  FaviconStore.swift
//  Skyscraper
//
//  ファビコン（サイトの絵札）を集めて、ホスト名を鍵に貯めておく係。
//
//  ── なぜ自前で書くのか ──
//  WKWebView はファビコンの API を出していない。WebKit の内側には
//  ちゃんと持っているのだが（Safari のタブに出ているのがそれだ）、
//  公開されているのは iOS の一部だけで macOS には無い。
//
//  ── なぜ JS で画像まで取らないのか ──
//  <link rel="icon"> の在り処を拾うところまではページ内の JS で良い。
//  だが画像の実体をページ内の fetch() で取ると CORS で死ぬ。
//  ファビコンを CDN に置いているサイトは珍しくないし、no-cors にすれば
//  opaque になって中身が読めない。<img> と canvas も同じで、
//  他所から来た絵を描いた時点で汚染され toDataURL が例外を投げる。
//  だからアプリ側の URLSession で取る。
//
//  その URLSession は .ephemeral 固定だ。Cookie を一切載せない。
//  絵を一枚もらうのに身分証を出す理由が無いし、こうしておけば
//  プライベートウィンドウでも普通の窓でも同じ経路で済む。
//
//  ── プライベートウィンドウはディスクに書かない ──
//  ファビコンがディスクに残るということは、訪れたホスト名が
//  ディスクに残るということだ。跡を残さないと言って開いた窓で
//  それをやったら台無しになる。読むのは可、書くのは不可。
//
//  ── SVG は写らない ──
//  NSImage は生の SVG データを解釈しない。今どき SVG しか置いていない
//  サイトは多いので、その分は素直に空欄のままにしてある。
//  画面外の WKWebView に読ませて takeSnapshot する手はあるが、
//  絵札一枚のために WebContent プロセスを立てるのは割に合わない。
//

import AppKit
import CryptoKit
import Foundation
import SwiftUI

// 絵札の持ち期限と枚数の上限。
//
// クラスの外に出してあるのは、間引きを主スレッドの外で回すため。
// @MainActor の型の中に置くと、static let でさえ主スレッド縛りになる
private enum FaviconLimits {
    // これを過ぎた絵札は起動時の間引きで捨てる。
    // 次に訪れた時に取り直されるので、失われるものは無い
    static let maxAge: TimeInterval = 60 * 60 * 24 * 30

    // これを過ぎたら、出しはするが裏で取り直す。
    // サイトがロゴを変えても、二度目の訪問で追いつく
    static let refreshAfter: TimeInterval = 60 * 60 * 24 * 7

    // 期限内でもこれを超えたら、古い順に落とす。
    // 一枚 1〜3KB なので容量ではなく、際限が無いこと自体への歯止め
    static let maxCount = 600
}

@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    // 貯める大きさ。帯に出すのは 16pt なので、Retina でも足りる
    static let side: CGFloat = 32

    // ホスト名 → 絵。手元の即答用
    private var memory: [String: NSImage] = [:]

    // 取りに行って何も得られなかったホスト。
    // 覚えておかないと、SVG しか置いていない相手を毎回叩きに行く羽目になる
    private var failed: Set<String> = []

    // 取得中のもの。同じホストのタブを何枚も開いた時に、
    // 同じ絵を人数分取りに行かせない。
    //
    // 中身が NSImage ではなく Data なのは Swift 6 の都合だ。
    // Task.value は戻り値が Sendable であることを要求するが、
    // NSImage は Sendable じゃない。焼き直した PNG のバイトを
    // 受け渡して、絵に戻すのは受け取った側でやる
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private let session: URLSession
    private let directory: URL?

    // ディスクに焼き付いた日。取り直しの判断に使う
    private var diskDate: [String: Date] = [:]

    // この起動で取り直しを始めたホスト。
    // 同じ相手を何度も叩かないための印
    private var revalidated: Set<String> = []

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        // 絵札一枚に身分証は要らない
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let bundleID = Bundle.main.bundleIdentifier ?? "net.live-on.inugamine.Skyscraper"
        directory = caches?
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Favicons", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - 引き出す

    // 手元にあるものだけ返す。通信は一切しない。
    // セッション復元の直後や、⇧⌘A の一覧はここだけを見る
    func cached(for host: String) -> NSImage? {
        if let image = memory[host] { return image }
        guard let image = readFromDisk(host) else { return nil }
        memory[host] = image
        return image
    }

    // 無ければ取りに行く。
    // candidates はページから拾った <link> の宛先（優先順）。
    // 最後に /favicon.ico を自分で足すので、空で渡しても構わない。
    //
    // ignoringCache が真なら、手元にあっても取りに行く（古びた分の取り直し）
    func icon(for host: String, candidates: [URL], allowDiskWrite: Bool,
              ignoringCache: Bool = false) async -> NSImage? {
        if !ignoringCache {
            if let image = cached(for: host) { return image }
            guard !failed.contains(host) else { return nil }
        }

        let task: Task<Data?, Never>
        if let running = inFlight[host] {
            task = running
        } else {
            task = Task { [weak self] () -> Data? in
                guard let self else { return nil }
                return await self.download(host: host,
                                           candidates: candidates,
                                           allowDiskWrite: allowDiskWrite)
            }
            inFlight[host] = task
        }

        let png = await task.value
        inFlight[host] = nil

        guard let png, let image = NSImage(data: png) else {
            // 取り直しに失敗しただけなら、今ある絵は捨てない。
            // 逐一叩かない印（failed）を付けるのは、
            // 一度も取れていない相手に対してだけだ
            if !ignoringCache { failed.insert(host) }
            return nil
        }
        memory[host] = image
        return image
    }

    // 取り直しの番を取る。
    //
    // 問い合わせではなく名乗りだ——真を返すのは一回だけで、
    // その場で印を付ける。同じサイトをタブで何枚も開いていても、
    // 取り直しは一度しか走らない
    func claimRevalidation(_ host: String) -> Bool {
        guard let date = diskDate[host],
              Date().timeIntervalSince(date) > FaviconLimits.refreshAfter,
              !revalidated.contains(host) else { return false }
        revalidated.insert(host)
        let age = Int(Date().timeIntervalSince(date))
        print("FaviconStore: refetching \(host) (\(age)s old)")
        return true
    }

    // MARK: - 取ってくる

    private func download(host: String, candidates: [URL], allowDiskWrite: Bool) async -> Data? {
        // SVG は NSImage が読めないので後ろへ回す。
        // 「SVG しか無い」相手はどのみち諦めるが、両方置いている相手は救える
        var urls = candidates.filter { $0.scheme == "http" || $0.scheme == "https" }
        urls.sort { a, b in
            let aSVG = a.pathExtension.lowercased() == "svg"
            let bSVG = b.pathExtension.lowercased() == "svg"
            return !aSVG && bSVG
        }
        // 昔ながらの置き場。<link> が一つも無いサイトはこれで拾える
        if let fallback = URL(string: "https://\(host)/favicon.ico") {
            urls.append(fallback)
        }

        for url in urls.prefix(4) {
            guard let raw = await fetch(url),
                  let image = Self.normalize(raw),
                  let png = Self.pngData(image) else { continue }
            if allowDiskWrite { writeToDisk(host, png) }
            return png
        }
        return nil
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        // 絵札のはずが何メガも返ってきたなら、それは絵札ではない
        guard !data.isEmpty, data.count <= 1_000_000 else { return nil }
        return data
    }

    // 受け取った絵を決まった大きさに焼き直す。
    // .ico は複数の寸法を抱えているので、NSImage に選ばせてから描く
    private static func normalize(_ data: Data) -> NSImage? {
        guard let source = NSImage(data: data), source.isValid,
              source.size.width > 0, source.size.height > 0 else { return nil }

        let box = NSRect(x: 0, y: 0, width: side, height: side)
        let result = NSImage(size: box.size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: box, from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result.isValid ? result : nil
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - ディスク

    // 鍵はホスト名の SHA-256。
    //
    // ホスト名をそのままファイル名にしないのは、国際化ドメインや
    // 妙に長い相手で足を掬われないためだ。
    // 中身を見て回れないが、ここは絵の置き場であって台帳ではない
    private func path(_ host: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(host.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }

    private func readFromDisk(_ host: String) -> NSImage? {
        guard let url = path(host), let data = try? Data(contentsOf: url) else { return nil }
        // 焼き付いた日を控える。これが取り直しの物差しになる
        diskDate[host] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return NSImage(data: data)
    }

    private func writeToDisk(_ host: String, _ png: Data) {
        guard let url = path(host) else { return }
        try? png.write(to: url, options: .atomic)
        diskDate[host] = Date()
    }

    // MARK: - 起動時の間引き

    // 古びた絵札を捨て、枚数を上限に収める。
    //
    // 「毎回空にする」という手は取らない。
    // ディスクに貯めている一番の目的は、セッション復元の直後に
    // 帯へ絵を並べることだ。毎回空にすれば前回のタブが全部空欄で始まるし、
    // 数百のホストを起動のたびに叩きに行くことになる
    func pruneOnLaunch() {
        guard let directory else {
            print("FaviconStore: no cache directory; prune skipped")
            return
        }
        // 数百枚の日付を見て回るだけの仕事だ。
        // 起動直後の一番道が混む時間に主スレッドを使う理由が無い
        Task.detached(priority: .utility) {
            Self.prune(directory: directory)
        }
    }

    nonisolated private static func prune(directory: URL) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            print("FaviconStore: could not read \(directory.path); prune skipped")
            return
        }

        let now = Date()
        var kept: [(url: URL, date: Date)] = []
        var expired = 0
        var overflow = 0

        for url in items {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > FaviconLimits.maxAge {
                try? manager.removeItem(at: url)
                expired += 1
            } else {
                kept.append((url, date))
            }
        }

        // 期限内でも多すぎるなら、新しい順に並べて尻を切る
        if kept.count > FaviconLimits.maxCount {
            kept.sort { $0.date > $1.date }
            for entry in kept[FaviconLimits.maxCount...] {
                try? manager.removeItem(at: entry.url)
                overflow += 1
            }
            kept.removeSubrange(FaviconLimits.maxCount...)
        }

        // 何も捨てなかった時でも必ず吐く。
        // 走ったのか黙っているのか分からない診断は診断にならない
        print("FaviconStore: prune \(items.count) found, "
              + "\(expired) expired, \(overflow) over limit, \(kept.count) left")
    }

    // 設定の「閲覧データを消去」から呼べるようにしておく。
    // 今は誰も呼んでいないが、絵札もサイトの痕跡には違いない
    func removeAll() {
        memory.removeAll()
        failed.removeAll()
        diskDate.removeAll()
        revalidated.removeAll()
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - 絵札の枠

// ファビコンを六角形の枠に落とす。
//
// 枠の色がピン留めを兼ねる——留めてあれば金、そうでなければ淡い金。
// 以前は行頭に金の菱形を置いていたが、絵札と菱形が並ぶと頭が混む。
// 飾りを一つ減らして枠に語らせる方が、字数も食わずデコらしい
struct FaviconBadge: View {
    let image: NSImage?
    let isPinned: Bool
    var side: CGFloat = 17

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(side * 0.22)
            } else {
                // 絵札の無い相手（SVG しか置いていないサイトなど）。
                // 枠だけを残して中は空にする。別の印を置くと
                // 「絵札のあるタブ」と紛らわしくなる
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .overlay(
            Hexagon(inset: side * 0.27)
                .stroke(isPinned ? Deco.gold : Deco.faintGold,
                        lineWidth: isPinned ? 1 : 0.7)
        )
    }
}
