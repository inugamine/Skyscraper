//
//  SettingsView.swift
//  Skyscraper
//
//  設定画面（⌘, で開く）。今はアップデート設定のみ。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 見出し ──
            HStack(spacing: 8) {
                Image(systemName: "diamond")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.gold)
                Text("Updates")
                    .font(.system(size: 14, design: .serif))
                    .tracking(3)
                    .foregroundColor(Deco.cream)
            }
            .padding(.bottom, 10)

            Zigzag(teeth: 18)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.bottom, 16)

            // ── 自動確認 ──
            Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatically check for updates")
                        .font(.system(size: 12, design: .serif))
                        .foregroundColor(Deco.cream)
                    Text("Skyscraper will periodically look for new versions.")
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.dimGold)
                }
            }
            .toggleStyle(.switch)
            .tint(Deco.gold)
            .padding(.bottom, 14)

            // ── 自動ダウンロード ──
            Toggle(isOn: $updater.automaticallyDownloadsUpdates) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatically download updates")
                        .font(.system(size: 12, design: .serif))
                        .foregroundColor(updater.automaticallyChecksForUpdates ? Deco.cream : Deco.faintGold)
                    Text("New versions will be downloaded and installed without asking.")
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(updater.automaticallyChecksForUpdates ? Deco.dimGold : Deco.faintGold)
                }
            }
            .toggleStyle(.switch)
            .tint(Deco.gold)
            .disabled(!updater.automaticallyChecksForUpdates)

            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 240)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    SettingsView(updater: Updater())
}
