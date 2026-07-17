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
                return [
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeOfflineWebApplicationCache,
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
        lastClearedMessage = String(localized: "Done. Data has been cleared.")
        // 一言表示は数秒で消す
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.lastClearedMessage = nil
        }
    }
}
