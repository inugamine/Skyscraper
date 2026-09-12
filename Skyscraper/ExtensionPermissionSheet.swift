//
//  ExtensionPermissionSheet.swift
//  Skyscraper
//
//  拡張機能を入れる前に、何を渡すことになるのかを見せるシート。
//
//  ── 見せ方の方針 ──
//  権限の綴り（scripting, declarativeNetRequest …）に対訳は当てない。
//  仕様で決まった機械的な名前で、数も増え続ける。全部に訳を用意すると、
//  知らない名前が来た時に黙って消える実装になりがちだ——
//  見えない権限が一番危ない。綴りはそのまま出し、重いものにだけ一言添える。
//
//  ── 個別に選ばせない ──
//  拡張は要求した権限が欠けると黙って壊れることが多く、その壊れ方が
//  利用者から見えない。「入れるか入れないか」だけを訊いて、
//  入れるなら要求通りに通す。例外はプライベートウィンドウの可否で、
//  これは拡張の動作そのものではなく、どこまで見せるかの話だから分けてある。
//

import SwiftUI
import WebKit

struct ExtensionPermissionSheet: View {
    let entry: WebExtensionManager.Loaded

    @Environment(\.dismiss) private var dismiss

    // 既定は入。切ると、プライベートの窓では拡張が何も見えなくなる——
    // uBOL なら遮断が黙って効かなくなる
    @State private var allowsPrivateData = true

    private var permissions: [ExtensionPermissionDigest.Item] {
        ExtensionPermissionDigest.permissions(of: entry.ext)
    }

    private var sites: [ExtensionPermissionDigest.Item] {
        ExtensionPermissionDigest.sites(of: entry.ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Zigzag(teeth: 20)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !sites.isEmpty {
                        sectionTitle("Access to websites")
                        ForEach(sites) { item in
                            itemRow(item)
                        }
                        Spacer().frame(height: 18)
                    }

                    if !permissions.isEmpty {
                        sectionTitle("Capabilities")
                        ForEach(permissions) { item in
                            itemRow(item)
                        }
                        Spacer().frame(height: 18)
                    }

                    if sites.isEmpty && permissions.isEmpty {
                        Text("This extension does not request any special access.")
                            .font(.system(size: 11, design: .serif))
                            .foregroundColor(Deco.dimGold)
                            .padding(.vertical, 8)
                    }

                    sectionTitle("Private Windows")

                    Toggle(isOn: $allowsPrivateData) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Let this extension work in private windows")
                                .font(.system(size: 12, design: .serif))
                                .foregroundColor(Deco.cream)
                            Text("If this is off, the extension sees nothing in private windows. Content blockers stop blocking there, without any warning.")
                                .font(.system(size: 10, design: .serif))
                                .foregroundColor(Deco.dimGold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Deco.gold)
                    .padding(.vertical, 6)
                }
                .padding(16)
            }

            footer
        }
        .frame(width: 460, height: 520)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
        .onAppear {
            allowsPrivateData = ExtensionPermissionStore.allowsPrivateData(for: entry.id)
        }
    }

    // ── 見出し ──

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add Extension")
                .font(.system(size: 15, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.cream)

            HStack(spacing: 8) {
                Text(verbatim: entry.displayName)
                    .font(.system(size: 13, design: .serif))
                    .foregroundColor(Deco.gold)
                Text(verbatim: entry.version)
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
            }

            Text("This extension is asking for the following. Allow it only if you trust where it came from.")
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "diamond")
                .font(.system(size: 9))
                .foregroundColor(Deco.gold)
            Text(title)
                .font(.system(size: 12, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.cream)
        }
        .padding(.bottom, 8)
    }

    // 一行。重いものには印を付ける
    private func itemRow(_ item: ExtensionPermissionDigest.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isBroad ? "exclamationmark.triangle" : "circle.fill")
                .font(.system(size: item.isBroad ? 10 : 5))
                .foregroundColor(item.isBroad ? Deco.rust : Deco.faintGold)
                .frame(width: 14, alignment: .center)
                .padding(.top, item.isBroad ? 1 : 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(item.isBroad ? Deco.cream : Deco.dimGold)

                if let note = item.note {
                    Text(verbatim: note)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.dimGold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // ── 足元 ──

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Deco.faintGold).frame(height: 1)

            HStack(spacing: 10) {
                Spacer()

                // 既定は「許可しない」側に置く。
                // Return を叩いただけで全サイトへの access が通ってはいけない
                button("Don't Allow", filled: false) {
                    WebExtensionManager.shared.deny(id: entry.id)
                    dismiss()
                }

                button("Allow", filled: true) {
                    WebExtensionManager.shared.approve(
                        id: entry.id,
                        allowsPrivateData: allowsPrivateData
                    )
                    dismiss()
                }
            }
            .padding(16)
        }
    }

    private func button(_ title: LocalizedStringKey,
                        filled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, design: .serif))
                .tracking(1)
                .foregroundColor(filled ? Deco.ink : Deco.gold)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Hexagon(inset: 6).fill(filled ? Deco.gold : Color.clear))
                .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
                .contentShape(Hexagon(inset: 6))
        }
        .buttonStyle(.plain)
    }
}
