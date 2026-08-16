//
//  PrivacyManager.swift
//  Skyscraper
//
//  閲覧データ（キャッシュ・Cookie 等)の削除を担う管理役。
//

import Foundation
import WebKit
import Combine

@MainActor
final class PrivacyManager: ObservableObject {

    // 削除の種類
    enum Scope: Identifiable {
        case cache      // キャッシュのみ（ログインは残る）
        case cookies    // Cookie のみ（ログインが切れる）
        case all        // 閲覧データすべて

        var id: String { title }

        var title: String {
            switch self {
            case .cache:   return String(localized: "Clear Cache")
            case .cookies: return String(localized: "Clear Cookies")
            case .all:     return String(localized: "Clear All Browsing Data")
            }
        }

        var confirmMessage: String {
            switch self {
            case .cache:
                return String(localized: "Cached files will be removed. Sign-ins are kept.")
            case .cookies:
                return String(localized: "Cookies will be removed. You will be signed out of most sites.")
            case .all:
                return String(localized: "All browsing data (cache, cookies, local storage) will be removed.")
            }
        }

        // WKWebsiteDataStore に渡すデータ種別
        var dataTypes: Set<String> {
            switch self {
            case .cache:
                // OfflineWebApplicationCache（AppCache）は macOS 26.2 で廃止。
                // 仕様自体がなくなっているので、外しても消し残しは出ない
                return [
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeFetchCache,
                ]
            case .cookies:
                return [WKWebsiteDataTypeCookies]
            case .all:
                return WKWebsiteDataStore.allWebsiteDataTypes()
            }
        }
    }

    // 確認ダイアログに出す対象（nil なら非表示）
    @Published var pendingScope: Scope? = nil
    // 「削除しました」の一言表示
    @Published var lastClearedMessage: String? = nil

    // 確認を求める（設定画面のボタンから呼ばれる）
    func requestClear(_ scope: Scope) {
        pendingScope = scope
    }

    // 実際に削除する（確認ダイアログの「削除」から呼ばれる)
    func performClear(_ scope: Scope) async {
        let store = WKWebsiteDataStore.default()
        let types = scope.dataTypes
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        flash(String(localized: "Done. Data has been cleared."))
    }

    // カメラ・マイクの「このサイトを覚えておく」を全部忘れる。
    // 次回からはまた一件ずつ訊きに行く
    func resetMediaPermissions() {
        MediaPermissionStore.shared.reset()
        flash(String(localized: "Done. Camera and microphone permissions have been reset."))
    }

    // 外部アプリで開く／開かないの「今後訊かない」を全部忘れる。
    // 一度「開かない」で覚えさせると、これが無い限り二度と開けなくなる
    func resetExternalSchemes() {
        ExternalSchemeStore.shared.reset()
        flash(String(localized: "Done. External app permissions have been reset."))
    }

    // 「このサイトでは常に許可」したポップアップの許可を全部忘れる
    func resetPopupAllowList() {
        PopupAllowList.shared.reset()
        flash(String(localized: "Done. Pop-up permissions have been reset."))
    }

    // 「このサイトでは訊かない」を忘れる。
    // 預かっているパスワードそのものには手を触れない（消すのは一覧の画面から）
    func resetPasswordNeverList() {
        PasswordNeverList.shared.reset()
        flash(String(localized: "Done. Password prompts have been reset."))
    }

    // 「危険を承知で続行」で通した証明書の例外を今すぐ忘れる。
    //
    // 放っておいてもアプリを終えば消える——そういう作りにしてある。
    // それでも札を出しておくのは、間違えて押した時に
    // アプリを再起動するしか道が無いと困るからだ
    func resetCertificateExceptions() {
        CertificateExceptionStore.shared.reset()
        flash(String(localized: "Done. Certificate exceptions have been cleared."))
    }

    // 一言表示を出して、数秒で消す
    private func flash(_ message: String) {
        lastClearedMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.lastClearedMessage = nil
        }
    }
}
