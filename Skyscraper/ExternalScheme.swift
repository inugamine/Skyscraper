//
//  ExternalScheme.swift
//  Skyscraper
//
//  WKWebView が自分では開けないスキームを、担当アプリへ引き渡す係。
//
//  mailto: / tel: / zoommtg: / itms-apps: などは、WKWebView に load させても
//  何も起きずに黙って終わる（利用者からは「リンクが死んでいる」ようにしか見えない）。
//  こういう URL は macOS に振り分けを任せる。
//
//  渡し先は名指ししない。NSWorkspace に「これを開けるアプリに渡してくれ」と
//  頼むだけなので、既定のメールソフトが Thunderbird なら Thunderbird が開く。
//  どのアプリが受け取るかをブラウザが決める筋合いはない。
//

import Foundation
import AppKit

@MainActor
final class ExternalSchemeStore {
    static let shared = ExternalSchemeStore()

    private let storageKey = "skyscraper.externalSchemes.v1"
    // "mailto" → 外部アプリで開くことを許したか
    private var decisions: [String: Bool]

    private init() {
        decisions = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Bool] ?? [:]
    }

    var hasSavedDecisions: Bool { !decisions.isEmpty }

    // 覚えた判断をすべて忘れる（設定画面から呼ぶ）
    func reset() {
        decisions.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - 引き渡し

    func open(_ url: URL, in window: NSWindow?) async {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return }

        // 担当アプリが一つも居ないなら、訊くだけ無駄なので黙って諦める。
        // （Zoom を入れていない Mac で zoommtg: を踏んだ場合など）
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            print("External scheme: no handler for \(scheme):")
            return
        }

        // 「今後訊かない」で覚えた判断があれば、それに従う
        if let remembered = decisions[scheme] {
            if remembered { NSWorkspace.shared.open(url) }
            return
        }

        let appName = FileManager.default.displayName(atPath: appURL.path)
        let (allowed, remember) = await ask(url: url,
                                            scheme: scheme,
                                            appName: appName,
                                            in: window)
        if remember {
            decisions[scheme] = allowed
            UserDefaults.standard.set(decisions, forKey: storageKey)
        }
        if allowed { NSWorkspace.shared.open(url) }
    }

    // MARK: - 確認ダイアログ

    private func ask(url: URL,
                     scheme: String,
                     appName: String,
                     in window: NSWindow?) async -> (allowed: Bool, remember: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Open this link in “\(appName)”?")
        alert.informativeText = Self.shortened(url)

        let open   = alert.addButton(withTitle: String(localized: "Open"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        // 誤って Return を叩いても外部アプリが起動しないよう、既定は「キャンセル」に置く
        open.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again for “\(scheme):” links")

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }

        return (response == .alertFirstButtonReturn,
                alert.suppressionButton?.state == .on)
    }

    // ダイアログに出す URL。長すぎると枠を押し広げるので頭だけ見せる
    private static func shortened(_ url: URL) -> String {
        let text = url.absoluteString
        let limit = 120
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
