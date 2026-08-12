//
//  PageExporter.swift
//  Skyscraper
//
//  今見ているページを紙・PDF・ファイルへ出す。
//
//  WKWebView は道具を持っているのに、macOS のメニューには何も繋がっていない。
//  ⌘P も ⌘S も無いブラウザでは、領収書一枚を手元に残せない。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
enum PageExporter {

    // MARK: - 印刷

    static func print(_ tab: Tab) {
        guard let webView = printable(tab) else { return }

        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        // 横は紙幅に合わせて縮める。等倍のままだと、幅の広いページが
        // 右端で切られたまま何枚も出る
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let operation = webView.printOperation(with: info)
        // WKWebView が返す印刷用のビューは大きさが未設定のまま来ることがあり、
        // そのまま走らせると白紙が一枚出る。中身の寸法を教えておく
        operation.view?.frame = webView.bounds
        operation.jobTitle = jobTitle(tab)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: - PDF

    static func exportPDF(_ tab: Tab) {
        guard let webView = printable(tab) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName(tab) + ".pdf"
        panel.canCreateDirectories = true

        present(panel, over: webView.window) { url in
            Task { @MainActor in
                do {
                    // 既定の WKPDFConfiguration は文書の全体を写す
                    //（画面に見えている範囲だけではない）
                    let data = try await pdfData(from: webView)
                    try data.write(to: url)
                } catch {
                    report(error, over: webView.window)
                }
            }
        }
    }

    // MARK: - ページの保存

    static func savePage(_ tab: Tab) {
        guard let webView = printable(tab) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let chooser = FormatChooser(panel: panel, baseName: suggestedName(tab))
        panel.accessoryView = chooser.view
        chooser.apply()

        present(panel, over: webView.window) { url in
            Task { @MainActor in
                do {
                    let data: Data
                    switch chooser.format {
                    case .webArchive:
                        // 画像も CSS も抱き込んだ一枚。あとから丸ごと開き直せる
                        data = try await webArchiveData(from: webView)
                    case .source:
                        // 今の DOM を書き出す。取ってきた生のソースではなく、
                        // スクリプトが組み立てた後の姿である点に注意
                        let html = try await webView.evaluateJavaScript(
                            "document.documentElement.outerHTML"
                        ) as? String ?? ""
                        data = Data(html.utf8)
                    }
                    try data.write(to: url)
                } catch {
                    report(error, over: webView.window)
                }
            }
        }
    }

    // MARK: - 保存の形式を選ぶ受け皿

    // NSSavePanel は allowedContentTypes を並べても選択欄を出してくれないので、
    // 自前の小さな選択欄を添える
    @MainActor
    private final class FormatChooser: NSObject {
        enum Format: Int {
            case webArchive
            case source

            var contentType: UTType {
                switch self {
                case .webArchive: return UTType("com.apple.webarchive") ?? .data
                case .source:     return .html
                }
            }

            var pathExtension: String {
                switch self {
                case .webArchive: return "webarchive"
                case .source:     return "html"
                }
            }
        }

        let view: NSView
        private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        private weak var panel: NSSavePanel?
        private let baseName: String

        var format: Format { Format(rawValue: popup.indexOfSelectedItem) ?? .webArchive }

        init(panel: NSSavePanel, baseName: String) {
            self.panel = panel
            self.baseName = baseName

            popup.addItem(withTitle: String(localized: "Web Archive"))
            popup.addItem(withTitle: String(localized: "Page Source"))

            let label = NSTextField(labelWithString: String(localized: "Format:"))
            let row = NSStackView(views: [label, popup])
            row.orientation = .horizontal
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            view = row

            super.init()
            popup.target = self
            popup.action = #selector(formatChanged)
        }

        @objc private func formatChanged() { apply() }

        // 選んだ形式に合わせて、拡張子と受け付ける型を揃える
        func apply() {
            panel?.allowedContentTypes = [format.contentType]
            panel?.nameFieldStringValue = baseName + "." + format.pathExtension
        }
    }

    // MARK: - WebKit の書き出し

    // createPDF / createWebArchiveData には async 版が生えていない
    //（Result を渡す形の完了通知は自動で橋渡しされない）ので、自分でくるむ

    private static func pdfData(from webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF { continuation.resume(with: $0) }
        }
    }

    private static func webArchiveData(from webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { continuation.resume(with: $0) }
        }
    }

    // MARK: - 下ごしらえ

    // 出せる中身があるか。ロビーと顛末書は紙に出しても白紙にしかならない
    private static func printable(_ tab: Tab) -> WKWebView? {
        guard !tab.isHome, tab.loadError == nil else {
            NSSound.beep()
            return nil
        }
        return tab.webView
    }

    private static func jobTitle(_ tab: Tab) -> String {
        if !tab.pageTitle.isEmpty { return tab.pageTitle }
        if let host = URL(string: tab.urlText)?.host() { return host }
        return String(localized: "Untitled")
    }

    // 保存名の下ごしらえ。
    // ファイル名に使えない文字（/ と :）は題名によく混ざるので均す
    private static func suggestedName(_ tab: Tab) -> String {
        let raw = jobTitle(tab)
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? String(localized: "Untitled") : trimmed
    }

    private static func present(_ panel: NSSavePanel,
                                over window: NSWindow?,
                                write: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            write(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private static func report(_ error: Error, over window: NSWindow?) {
        Swift.print("PageExporter: failed — \(error)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not save the page")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
