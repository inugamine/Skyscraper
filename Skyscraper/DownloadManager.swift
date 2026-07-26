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

import SwiftUI
import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

// MARK: - 一件ぶん

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL?
    let filename: String
    let destination: URL

    @Published var received: Int64 = 0
    @Published var total: Int64 = -1        // 不明なら -1
    @Published var state: State = .running

    // 中止するために本体を握っておく。所有はしない
    fileprivate weak var download: WKDownload?
    private var observers: [NSKeyValueObservation] = []

    init(download: WKDownload, destination: URL) {
        self.download = download
        self.sourceURL = download.originalRequest?.url
        self.destination = destination
        self.filename = destination.lastPathComponent

        // 進捗は WKDownload が持つ Progress をそのまま見る。自前で数える必要はない。
        // fractionCompleted は必ず KVO で流れてくるので、それを合図に
        // 実際のバイト数を読み直す
        let progress = download.progress
        observers.append(
            progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] p, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.received = p.completedUnitCount
                    self.total = p.totalUnitCount
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

    private override init() { super.init() }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    // MARK: - 操作

    func stop(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .cancelled
    }

    func revealInFinder(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.destination])
    }

    func open(_ item: DownloadItem) {
        NSWorkspace.shared.open(item.destination)
    }

    // 終わったものを棚から下ろす。実行中のものは残す
    func clearFinished() {
        items.removeAll { $0.state != .running }
        isShelfVisible = !items.isEmpty
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
            let item = DownloadItem(download: download, destination: url)
            self.items.append(item)
            self.isShelfVisible = true

            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        item(for: download)?.state = .finished
    }

    func download(_ download: WKDownload,
                  didFailWithError error: Error,
                  resumeData: Data?) {
        print("Download failed: \(error.localizedDescription)")
        guard let item = item(for: download) else { return }
        // 自分で止めた時も didFailWithError が来る。上書きしない
        if item.state == .running {
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

                Button { downloads.clearFinished() } label: {
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

            if item.state == .running {
                // 総量が分からない時は満たさず、受信量だけを出す
                ZStack(alignment: .leading) {
                    Rectangle().fill(Deco.faintGold.opacity(0.4))
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Deco.gold)
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
        case .finished:  return "checkmark"
        case .failed:    return "exclamationmark.triangle"
        case .cancelled: return "minus"
        }
    }

    private var statusText: String {
        switch item.state {
        case .running:          return item.progressText
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
