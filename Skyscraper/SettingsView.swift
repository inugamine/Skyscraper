//
//  SettingsView.swift
//  Skyscraper
//
//  設定画面（⌘, で開く）。
//
//  項目が増えて縦一枚では画面の小さい Mac で下がはみ出すようになったので、
//  「一般」「プライバシー」「ライセンス」の三枚に分けて、
//  それぞれの中を巻物（ScrollView）にしてある。
//  窓の高さは中身に関係なく固定で、伸びるのは中の巻物だけだ。
//

import SwiftUI
import Foundation

struct SettingsView: View {
    @ObservedObject var updater: Updater
    // ブックマークの持ち主。同期の入り切りを伝えるためだけに受け取る
    let bookmarks: BookmarkStore
    @StateObject private var privacy = PrivacyManager()
    @AppStorage(TabManager.restoreSessionKey) private var restoresSession = true
    @AppStorage(SleepBlocker.enabledKey) private var preventsSleepDuringVideo = true
    @AppStorage(BookmarkSync.enabledKey) private var syncsBookmarks = true
    @State private var showingPasswords = false
    @State private var showingExtensions = false
    @State private var pane: Pane = .general

    // ── 頁 ──
    //
    // SwiftUI に Section という型が既に居るので、そちらとぶつからない名前にする
    private enum Pane: String, CaseIterable, Identifiable {
        case general, privacy, licenses

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .general:  "General"
            case .privacy:  "Privacy"
            case .licenses: "Licenses"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            paneBar

            // ── 中身 ──
            //
            // 頁を切り替えた時に前の頁の巻き位置が残らないよう、
            // .id で「別の中身になった」と伝えて巻き直させる
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch pane {
                    case .general:  generalPane
                    case .privacy:  privacyPane
                    case .licenses: licensePane
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .id(pane)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: 520, height: 580)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: privacy.lastClearedMessage)
        .sheet(isPresented: $showingPasswords) {
            PasswordListView()
        }
        .sheet(isPresented: $showingExtensions) {
            WebExtensionListView()
        }
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

    // ══════════════════════════════════════════════
    //  頁の見出し（六角形の札を横に並べる）
    // ══════════════════════════════════════════════

    private var paneBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Pane.allCases) { item in
                    let isCurrent = (item == pane)

                    Button {
                        pane = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 11, design: .serif))
                            .tracking(2)
                            .foregroundColor(isCurrent ? Deco.ink : Deco.gold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Hexagon(inset: 7).fill(isCurrent ? Deco.gold : Color.clear))
                            .overlay(Hexagon(inset: 7).stroke(isCurrent ? Deco.gold : Deco.faintGold, lineWidth: 1))
                            .contentShape(Hexagon(inset: 7))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Zigzag(teeth: 26)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 24)
        }
    }

    // ══════════════════════════════════════════════
    //  足元（版数と権利表示）
    // ══════════════════════════════════════════════

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Zigzag(teeth: 26)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(height: 5)
                .padding(.bottom, 10)

            HStack(spacing: 12) {
                Text(verbatim: Self.versionLine)
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)

                Spacer()

                Text(verbatim: "© 2026 inugamine — Apache License 2.0")
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // ══════════════════════════════════════════════
    //  一般
    // ══════════════════════════════════════════════

    @ViewBuilder
    private var generalPane: some View {

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
                    .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Deco.gold)
        .disabled(!updater.automaticallyChecksForUpdates)
        .padding(.bottom, 22)

        // ══ 再生 ══
        sectionHeader("Playback")

        // ── 動画中のスリープ抑制 ──
        Toggle(isOn: $preventsSleepDuringVideo) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep the display awake during video")
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.cream)
                Text("The screen saver and display sleep are held off while a video is playing.")
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Deco.gold)
        .padding(.bottom, 22)

        // ══ iCloud ══
        sectionHeader("iCloud")

        // ── ブックマークの持ち回り ──
        //
        // iCloud に入っていない人の所では、これを入れても
        // 何も起きない（BookmarkSync が黙って見送る）。
        // それでも札を出すのは、入っている上で
        //「この Mac では持ち回したくない」人の逃げ道になるからだ
        Toggle(isOn: $syncsBookmarks) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync bookmarks across your Macs")
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.cream)
                Text("Bookmarks are saved to your iCloud account. If the content differs across multiple Macs, the content from the Mac where the changes were last made takes precedence.")
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Deco.gold)
        .padding(.bottom, 22)
        .onChange(of: syncsBookmarks) { _, _ in
            // 入れ直した直後は、手元と向こうが食い違っている見込みが高い。
            // 切られた時は待ちの列を破棄させる
            bookmarks.syncSettingChanged()
        }

        // ══ 拡張機能 ══
        sectionHeader("Extensions")

        actionRow("Manage Extensions…", note: Self.extensionSummary) {
            showingExtensions = true
        }
    }

    // ══════════════════════════════════════════════
    //  プライバシー
    // ══════════════════════════════════════════════

    @ViewBuilder
    private var privacyPane: some View {

        // ══ セッション ══
        sectionHeader("Session")

        // ── セッション復元 ──
        // 既存のトグルと向きを揃え、「オンにすると何が起きるか」で書く。
        // 「保存しない」にするとオン＝しないの二重否定になる
        Toggle(isOn: $restoresSession) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reopen tabs on next launch")
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.cream)
                Text("Tab addresses are saved on quit. Turning this off also disables recovery after a crash.")
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Deco.gold)
        .padding(.bottom, 22)
        .onChange(of: restoresSession) { _, enabled in
            // 切られた瞬間に保存済みのタブ一覧を消す。
            // 次の保存まで待つと、その間ディスクに残り続けてしまう
            if !enabled { TabManager.forgetSavedSession() }
        }

        // ══ 閲覧データ ══
        sectionHeader("Browsing Data")

        VStack(alignment: .leading, spacing: 10) {
            clearButton(.cache,
                        note: "Removes cached files. Sign-ins are kept.")
            clearButton(.cookies,
                        note: "Removes cookies. You will be signed out of most sites.")
            clearButton(.all,
                        note: "Removes cache, cookies and local storage.")
        }
        .padding(.bottom, 22)

        // ══ パスワード ══
        sectionHeader("Passwords")

        VStack(alignment: .leading, spacing: 10) {
            // 預かっているログイン情報の一覧
            actionRow("Saved Passwords…",
                      note: "Kept in the macOS keychain, not in a file of our own.") {
                showingPasswords = true
            }

            // 「このサイトでは訊かない」の記憶を忘れる
            actionRow("Reset Password Prompts",
                      note: "Sites you told Skyscraper to stop asking will be asked about again.") {
                privacy.resetPasswordNeverList()
            }
        }
        .padding(.bottom, 22)

        // ══ 許可 ══
        sectionHeader("Permissions")

        VStack(alignment: .leading, spacing: 10) {
            // カメラ・マイクのサイト別許可を忘れる
            actionRow("Reset Camera & Microphone Permissions",
                      note: "Sites will be asked about again.") {
                privacy.resetMediaPermissions()
            }

            // 外部アプリで開く／開かないの記憶を忘れる
            actionRow("Reset External App Permissions",
                      note: "Links will be confirmed again.") {
                privacy.resetExternalSchemes()
            }

            // 「このサイトでは常に許可」したポップアップの記憶を忘れる
            actionRow("Reset Pop-up Permissions",
                      note: "Pop-ups will be blocked again.") {
                privacy.resetPopupAllowList()
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
    }

    // ══════════════════════════════════════════════
    //  ライセンス
    // ══════════════════════════════════════════════

    @ViewBuilder
    private var licensePane: some View {
        sectionHeader("Acknowledgements")
        AcknowledgementsList()
    }

    // ══════════════════════════════════════════════
    //  部品
    // ══════════════════════════════════════════════

    // 表示用のバージョン。MARKETING_VERSION と CURRENT_PROJECT_VERSION は
    // ビルド時に Info.plist へ流し込まれるので、ここでは読むだけ
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Skyscraper \(short) (\(build))"
    }

    // 設定画面に出す一行の要約。
    // 一覧の中身はシート側で見せるので、ここは数だけでいい。
    //
    // 「～ extensions are on」と書かないのは、英語では単数の時に
    // are / extensions が崩れるため。数だけを並べれば両言語で破綻がない
    private static var extensionSummary: LocalizedStringKey {
        let all = WebExtensionManager.shared.loaded
        guard !all.isEmpty else { return "No extensions are loaded." }
        let active = all.filter(\.isEnabled).count
        return "\(active) of \(all.count) enabled."
    }

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

    // 六角形の札と、その右に添える説明。
    // 同じ形が何度も並ぶので一つにまとめてある。
    //
    // 見出しを Text で受け取るのは、Scope.title が
    // String(localized:) で訳し終わった String だからだ。
    // LocalizedStringKey に詰め直すと、訳文をもう一度鍵として
    // 引きに行くことになる
    private func actionRow(_ title: LocalizedStringKey,
                           note: LocalizedStringKey,
                           action: @escaping () -> Void) -> some View {
        actionRow(label: Text(title), note: note, action: action)
    }

    private func actionRow(label: Text,
                           note: LocalizedStringKey,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                label
                    .font(.system(size: 11, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()

            // HStack の中の Text は、幅が足りないと黙って一行に切り詰められる。
            // 縦だけ理想の高さを使わせて、折り返しを許す
            Text(note)
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func clearButton(_ scope: PrivacyManager.Scope, note: LocalizedStringKey) -> some View {
        actionRow(label: Text(scope.title), note: note) {
            privacy.requestClear(scope)
        }
    }
}

#Preview {
    SettingsView(updater: Updater(), bookmarks: BookmarkStore())
}
