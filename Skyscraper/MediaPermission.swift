//
//  MediaPermission.swift
//  Skyscraper
//
//  カメラ・マイクの使用許可をサイトごとに預かる係。
//
//  WKWebView は requestMediaCapturePermissionFor を実装しない限り、
//  getUserMedia() を問答無用で拒否する（エラーすら分かりにくい）。
//  ここで許可の判断と、サイトごとの記憶を引き受ける。
//

import Foundation
import AppKit
import WebKit

@MainActor
final class MediaPermissionStore {
    static let shared = MediaPermissionStore()

    private let storageKey = "skyscraper.mediaPermissions.v1"
    // "https://example.com|camera" → 許可したか
    private var decisions: [String: Bool]

    private init() {
        decisions = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Bool] ?? [:]
    }

    var hasSavedDecisions: Bool { !decisions.isEmpty }

    // 覚えた許可をすべて忘れる（設定画面から呼ぶ）
    func reset() {
        decisions.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - 判断

    // origin は保存用のキー（scheme://host:port）、host は画面に出す名前
    func decide(origin: String,
                host: String,
                type: WKMediaCaptureType,
                in window: NSWindow?) async -> WKPermissionDecision {
        let keys = Self.deviceKeys(for: type).map { "\(origin)|\($0)" }

        // カメラとマイクを両方要求された場合、片方でも拒否済みなら訊かずに断る。
        // 両方とも記憶済みならその通りにする
        let saved = keys.compactMap { decisions[$0] }
        if saved.contains(false) {
            return .deny
        }
        if saved.count == keys.count {
            return .grant
        }

        let (allowed, remember) = await ask(host: host, type: type, in: window)
        if remember {
            for key in keys { decisions[key] = allowed }
            UserDefaults.standard.set(decisions, forKey: storageKey)
        }
        return allowed ? .grant : .deny
    }

    // MARK: - 問い合わせダイアログ

    private func ask(host: String,
                     type: WKMediaCaptureType,
                     in window: NSWindow?) async -> (allowed: Bool, remember: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Self.question(host: host, type: type)
        alert.informativeText = String(localized: "Allow this only if you trust the site.")

        let allow = alert.addButton(withTitle: String(localized: "Allow"))
        let deny  = alert.addButton(withTitle: String(localized: "Don't Allow"))
        // 誤って Return を叩いても許可にならないよう、既定は「許可しない」に置く
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\r"

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Remember my choice for this site")

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

    // MARK: - 小物

    // WKSecurityOrigin から保存用のキーを組む。
    // WKSecurityOrigin はメインスレッドで受け取った直後に文字列化して使う
    nonisolated static func storageOrigin(_ origin: WKSecurityOrigin) -> String {
        let scheme = origin.`protocol`
        var text = scheme.isEmpty ? origin.host : "\(scheme)://\(origin.host)"
        if origin.port != 0 { text += ":\(origin.port)" }
        return text
    }

    private static func deviceKeys(for type: WKMediaCaptureType) -> [String] {
        switch type {
        case .camera:              return ["camera"]
        case .microphone:          return ["microphone"]
        case .cameraAndMicrophone: return ["camera", "microphone"]
        @unknown default:          return ["unknown"]
        }
    }

    private static func question(host: String, type: WKMediaCaptureType) -> String {
        let site = host.isEmpty ? String(localized: "This site") : host
        switch type {
        case .camera:
            return String(localized: "“\(site)” would like to use your camera.")
        case .microphone:
            return String(localized: "“\(site)” would like to use your microphone.")
        case .cameraAndMicrophone:
            return String(localized: "“\(site)” would like to use your camera and microphone.")
        @unknown default:
            return String(localized: "“\(site)” would like to use a capture device.")
        }
    }
}
