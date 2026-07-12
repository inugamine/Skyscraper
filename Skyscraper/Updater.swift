//
//  Updater.swift
//  Skyscraper
//
//  Sparkle による自動更新の管理役。
//

import Foundation
import Sparkle
import SwiftUI
import Combine

// Sparkle の更新チェックを SwiftUI から使えるようにする管理役。
// アプリ起動時に自動でチェックし、メニューからの手動チェックも受け付ける。
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    // 「アップデートを確認」メニューを押せるかどうか
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true で、起動時に自動チェックが走る
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Sparkle 側の「今チェックできる状態か」を UI に反映する
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    // 手動での更新チェック（メニューから呼ばれる）
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
