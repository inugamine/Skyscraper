//
//  WebExtensionListView.swift
//  Skyscraper
//
//  設定画面から開く、拡張機能の一覧。
//  読み込まれているものを並べ、切り替えと置き場所の案内を出す。
//

import SwiftUI

struct WebExtensionListView: View {
    @ObservedObject private var manager = WebExtensionManager.shared
    @Environment(\.dismiss) private var dismiss

    // 切り替えた直後だけ「リロードが要る」と伝える。
    // DNR もコンテンツスクリプトもページ読み込み時に当たるので、
    // 開いたままのページには効かない
    @State private var needsReloadNotice = false
    // 許諾シートを出す相手。nil なら出さない
    @State private var reviewing: WebExtensionManager.Loaded?
    // 削除の確認を出す相手。nil なら出さない
    @State private var removing: WebExtensionManager.Loaded?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Zigzag(teeth: 20)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 16)

            if manager.loaded.isEmpty {
                empty
            } else {
                list
            }

            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: needsReloadNotice)
        .sheet(item: $reviewing) { entry in
            ExtensionPermissionSheet(entry: entry)
        }
        .confirmationDialog(
            removing.map { Text("Remove “\($0.displayName)”?") } ?? Text(""),
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = removing {
                Button("Remove", role: .destructive) {
                    manager.remove(id: entry.id)
                    needsReloadNotice = true
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("The extension folder is moved to the Trash. Its settings inside Skyscraper are forgotten.")
        }
    }

    // ── 見出し ──

    private var header: some View {
        HStack {
            Text("Extensions")
                .font(.system(size: 15, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.cream)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(Deco.dimGold)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // 出所のバッジ。
    // 三項演算子を Text に直接渡すと LocalizedStringKey と String の
    // どちらに解されるかが文脈依存になるので、型を明示して切り出す
    private static func sourceLabel(_ source: WebExtensionManager.Source) -> LocalizedStringKey {
        source == .bundled ? "Bundled" : "Added by you"
    }

    // 目ボタンの説明。三項演算子を .help() に直接渡すと
    // String と解されて翻訳が当たらないので、sourceLabel と同じやり方で逃がす
    private static func actionVisibilityHelp(_ shows: Bool) -> LocalizedStringKey {
        shows
            ? "Hide the button from the toolbar. The extension keeps working."
            : "Show the button in the toolbar."
    }

    // ── 一覧 ──

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(manager.loaded) { entry in
                    row(entry)
                }
            }
            .padding(16)
        }
    }

    private func row(_ entry: WebExtensionManager.Loaded) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.displayName)
                    .font(.system(size: 13, design: .serif))
                    .foregroundColor(entry.isRunning ? Deco.cream : Deco.dimGold)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(verbatim: entry.version)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.dimGold)

                    Text(Self.sourceLabel(entry.source))
                        .font(.system(size: 9, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.faintGold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 0.5))

                    // 許諾の状態。通っているものには何も出さない
                    if entry.review == .pending {
                        badge("Needs review", color: Deco.gold)
                    } else if entry.review == .denied {
                        badge("Not allowed", color: Deco.rust)
                    }
                }
            }

            Spacer(minLength: 8)

            // 未確認・断ったものは、トグルではなく確認への入口を出す。
            // ここにトグルを置くと、許諾を見ずに入にできてしまう
            if entry.review != .approved {
                Button {
                    reviewing = entry
                } label: {
                    Text("Review\u{2026}")
                        .font(.system(size: 11, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.gold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .overlay(Hexagon(inset: 5).stroke(Deco.gold, lineWidth: 1))
                        .contentShape(Hexagon(inset: 5))
                }
                .buttonStyle(.plain)
            } else {
                // ツールバーにボタンを出すか。
                // 拡張の入切とは別なので、切っても遮断は動き続ける。
                // 切られている拡張にはそもそもボタンが無いので伸ばす
                Button {
                    manager.setShowsAction(!entry.showsAction, for: entry.id)
                } label: {
                    Image(systemName: entry.showsAction ? "eye" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundColor(entry.showsAction ? Deco.gold : Deco.dimGold)
                        .frame(width: 30, height: 24)
                        .overlay(Hexagon(inset: 5).stroke(
                            entry.showsAction ? Deco.faintGold : Deco.faintGold.opacity(0.5),
                            lineWidth: 0.5
                        ))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.isEnabled)
                .opacity(entry.isEnabled ? 1 : 0.35)
                .help(Self.actionVisibilityHelp(entry.showsAction))

                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { newValue in
                        manager.setEnabled(newValue, for: entry.id)
                        needsReloadNotice = true
                    }
                ))
                .toggleStyle(.switch)
                .tint(Deco.gold)
                .labelsHidden()
            }

            // 利用者が入れたものだけ消せる。
            // 同梱版は消しても次の起動で戻るので、ボタン自体を出さない
            if entry.source == .user {
                Button {
                    removing = entry
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Deco.dimGold)
                        .frame(width: 30, height: 24)
                        .overlay(Hexagon(inset: 5).stroke(Deco.faintGold.opacity(0.5), lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this extension.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Deco.panel2)
        .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 0.5))
    }

    // 行の状態を示す小さな札
    private func badge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, design: .serif))
            .tracking(1)
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Hexagon(inset: 4).stroke(color.opacity(0.7), lineWidth: 0.5))
    }

    // ── 何も無いとき ──

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "puzzlepiece")
                .font(.system(size: 26))
                .foregroundColor(Deco.faintGold)
            Text("No extensions are loaded.")
                .font(.system(size: 12, design: .serif))
                .foregroundColor(Deco.dimGold)
            Text("Add an unpacked extension folder (one containing manifest.json) with the button below.")
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.faintGold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // ── 足元 ──

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Deco.faintGold).frame(height: 1)

            // 切り替えた直後だけ出す一言。
            //
            // 通信遮断（DNR）は WebKit が生きているページにも即座に反映することが
            // 確かめられているが、コンテンツスクリプト（整形フィルタ）は
            // ページ読み込み時に入るので、既に開いているページでは
            // 変わらない部分が残る。断定せずに「残ることがある」とだけ伝える
            if needsReloadNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Some changes only appear after a page is reloaded.")
                        .font(.system(size: 10, design: .serif))
                }
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // 取り込みや削除の失敗。ダイアログではなくここに出す
            if let error = manager.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(verbatim: error)
                        .font(.system(size: 10, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(Deco.rust)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            HStack(spacing: 12) {
                // フォルダを選んでその場で取り込む。
                // 読めたらそのまま許諾シートへ——押し忘れて
                // 「入れたのに動かない」にならないように
                Button {
                    Task {
                        if let id = await manager.addFromPanel(),
                           let entry = manager.loaded.first(where: { $0.id == id }) {
                            reviewing = entry
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("Add Extension\u{2026}")
                            .font(.system(size: 11, design: .serif))
                            .tracking(1)
                    }
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    manager.revealUserExtensionsDirectory()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Open Extensions Folder")
                            .font(.system(size: 11, design: .serif))
                            .tracking(1)
                    }
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(16)
        }
    }
}

#Preview {
    WebExtensionListView()
}
