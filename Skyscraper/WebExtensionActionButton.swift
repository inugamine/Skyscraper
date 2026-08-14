//
//  WebExtensionActionButton.swift
//  Skyscraper
//
//  アドレスバー右端に並ぶ、拡張機能のボタン。
//
//  ── WebKit が用意してくれるもの ──
//  アイコン（action.icon(for:)）、名前（label）、バッジ（badgeText）、
//  そして popup の NSPopover 一式（popupPopover）まで WebKit 側が持っている。
//  中身の WebView も寸法調整も自動で、閉じれば closePopup() まで呼ばれる。
//
//  ── こちらの仕事 ──
//  ・ボタンを描く（アール・デコの他の道具と揃える）
//  ・押されたら context.performAction(for:) を呼ぶ
//  ・popover を出す位置（＝ボタンの実体）を WebKit に教える
//
//  位置合わせのために NSView の参照が要るが、SwiftUI のボタンからは
//  自分の NSView を取れない。目印だけを NSViewRepresentable で敷いて、
//  その実体を拡張ごとに控えておく（ExtensionActionAnchorRegistry）。
//

import AppKit
import SwiftUI
import WebKit

// MARK: - popover を出す位置の控え

// 拡張ごとに「ボタンの実体」を一つ覚えておく置き場。
//
// 窓が複数あると同じ拡張のボタンも複数になるが、popup を出すのは
// 手前の窓の一つだけなので、最後に画面へ現れたものを正とする。
//
// 弱参照にしてはいけない。SwiftUI は NSViewRepresentable が作った
// NSView を自分の都合で作り直すので、弱参照だと押した瞬間に
// nil になっていることがある（実測して anchor=false になった）。
// 拡張の数だけの小さなビューを抱えるだけなので、強参照で持つ
@MainActor
final class ExtensionActionAnchorRegistry {
    static let shared = ExtensionActionAnchorRegistry()

    private var anchors: [String: NSView] = [:]

    private init() {}

    func register(_ view: NSView, forExtension id: String) {
        anchors[id] = view
    }

    // 窓に載っているものだけを返す。
    // 窓を閉じた後の抜け殻を掴むと popover の行き先が無くなる。
    //
    // 鍵は必ず context.uniqueIdentifier を使うこと。
    // デリゲート側は context しか持っていないので、
    // フォルダ名で登録すると、鍵が違って永遠に見つからない
    func view(forExtension id: String) -> NSView? {
        guard let view = anchors[id], view.window != nil else { return nil }
        return view
    }
}

// ボタンの背後に敷く目印。
// 見た目には何も足さず、NSView の実体だけを控えに登録する。
//
// クリックを奪うとボタンが押せなくなるので、hitTest で逃がす
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ExtensionActionAnchor: NSViewRepresentable {
    let extensionID: String

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        ExtensionActionAnchorRegistry.shared.register(view, forExtension: extensionID)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // 窓を移ったり作り直されたりした時のために、毎回控え直す
        ExtensionActionAnchorRegistry.shared.register(view, forExtension: extensionID)
    }
}

// MARK: - ボタン一つぶん

struct WebExtensionActionButton: View {
    @ObservedObject var tab: Tab
    let entry: WebExtensionManager.Loaded

    @State private var hovering = false

    // このタブに対する action。
    // タブごとに実体が違うので、描くたびに引き直す。
    // tab.extensionActionRevision が変わると body が組み直され、
    // 新しいアイコンとバッジが読まれる
    private var action: WKWebExtension.Action? {
        _ = tab.extensionActionRevision
        return entry.context.action(for: tab)
    }

    var body: some View {
        if let action {
            Button {
                // 押された事実を WebKit へ渡す。
                // popup を持つ拡張なら presentActionPopup が飛んでくるし、
                // 持たない拡張なら onClicked のイベントが発火する。
                // ユーザー操作の記録（activeTab 権限）もこの中で行われる
                entry.context.performAction(for: tab)
            } label: {
                icon(action)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .bottomTrailing) {
                        badge(action)
                    }
                    .background(ExtensionActionAnchor(
                        extensionID: entry.context.uniqueIdentifier
                    ))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(action.isEnabled ? 1 : 0.4)
            .disabled(!action.isEnabled)
            .onHover { hovering = $0 }
            .help(action.label.isEmpty ? entry.displayName : action.label)
        }
    }

    // 拡張が持つアイコン。取れなければパズル片で代用する
    @ViewBuilder
    private func icon(_ action: WKWebExtension.Action) -> some View {
        if let image = action.icon(for: CGSize(width: 16, height: 16)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
                // 黒地に載るので、暗いアイコンが沈まないよう少し持ち上げる
                .opacity(hovering ? 1 : 0.85)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13))
                .foregroundColor(Deco.gold)
        }
    }

    // 遮断数などの小さな数字。空文字なら何も出さない
    @ViewBuilder
    private func badge(_ action: WKWebExtension.Action) -> some View {
        let text = action.badgeText
        if !text.isEmpty {
            Text(verbatim: text)
                .font(.system(size: 8, design: .serif))
                .foregroundColor(Deco.ink)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule().fill(Deco.gold))
                .offset(x: 3, y: 1)
                .fixedSize()
        }
    }
}

// MARK: - 並び

// 有効な拡張ぶんのボタンを横に並べる。
// 拡張が無ければ何も出さない（アドレスバーの幅を食わない）
struct WebExtensionActionBar: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var manager = WebExtensionManager.shared

    var body: some View {
        ForEach(manager.loaded.filter(\.isEnabled)) { entry in
            WebExtensionActionButton(tab: tab, entry: entry)
        }
    }
}
