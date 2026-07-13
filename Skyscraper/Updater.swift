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
// 自動更新のオン/オフ設定は Sparkle 自身が UserDefaults に保存する。
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    // 「アップデートを確認」メニューを押せるかどうか
    @Published var canCheckForUpdates = false

    // 自動で更新を確認するか（設定画面のスイッチと連動）
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    // 更新を自動でダウンロードするか（設定画面のスイッチと連動）
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init() {
        // startingUpdater: true で、起動時に自動チェックが走る
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller

        // Sparkle が保存している現在の設定を初期値として読み込む
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates

        // Sparkle 側の「今チェックできる状態か」を UI に反映する
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    // 手動での更新チェック（メニューから呼ばれる）
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
