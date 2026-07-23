//
//  SettingsView.swift
//  Skyscraper
//
//  設定画面（⌘, で開く）。アップデート設定とプライバシー。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: Updater
    @StateObject private var privacy = PrivacyManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ══ アップデート ══
            sectionHeader("Updates")

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
            .padding(.bottom, 22)

            // ══ プライバシー ══
            sectionHeader("Privacy")

            VStack(alignment: .leading, spacing: 10) {
                clearButton(.cache,
                            note: "Removes cached files. Sign-ins are kept.")
                clearButton(.cookies,
                            note: "Removes cookies. You will be signed out of most sites.")
                clearButton(.all,
                            note: "Removes cache, cookies and local storage.")

                // カメラ・マイクのサイト別許可を忘れる
                HStack(spacing: 12) {
                    Button {
                        privacy.resetMediaPermissions()
                    } label: {
                        Text("Reset Camera & Microphone Permissions")
                            .font(.system(size: 11, design: .serif))
                            .tracking(1)
                            .foregroundColor(Deco.gold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Text("Sites will be asked about again.")
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.dimGold)

                    Spacer()
                }
            }

            // 完了の一言
            if let message = privacy.lastClearedMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11, design: .serif))
                }
                .foregroundColor(Deco.gold)
                .padding(.top, 12)
                .transition(.opacity)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 520)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: privacy.lastClearedMessage)
        // 確認ダイアログ
        .confirmationDialog(
            privacy.pendingScope?.title ?? "",
            isPresented: Binding(
                get: { privacy.pendingScope != nil },
                set: { if !$0 { privacy.pendingScope = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let scope = privacy.pendingScope {
                Button(scope.title, role: .destructive) {
                    Task { await privacy.performClear(scope) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let scope = privacy.pendingScope {
                Text(scope.confirmMessage)
            }
        }
    }

    // ── 部品 ──

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "diamond")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.gold)
                Text(title)
                    .font(.system(size: 14, design: .serif))
                    .tracking(3)
                    .foregroundColor(Deco.cream)
            }
            .padding(.bottom, 10)

            Zigzag(teeth: 18)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.bottom, 16)
        }
    }

    private func clearButton(_ scope: PrivacyManager.Scope, note: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Button {
                privacy.requestClear(scope)
            } label: {
                Text(scope.title)
                    .font(.system(size: 11, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text(note)
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)

            Spacer()
        }
    }
}

#Preview {
    SettingsView(updater: Updater())
}
