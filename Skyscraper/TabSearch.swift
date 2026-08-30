//
//  TabSearch.swift
//  Skyscraper
//
//  ⇧⌘A。開いている全ての窓のタブを串刺しで探して飛ぶ。
//
//  ── なぜ別立てなのか ──
//  アドレスバーの候補一覧（AddressSuggestions）にも「開いているタブ」は
//  出るが、あちらは自分の窓の中だけを見ている。
//  窓を三枚も開くと「どこかで開いたはずのあのページ」を探す手が無くなる。
//  こちらは TabManager.openWindows を全部歩く。
//
//  飛び先が別の窓だった場合は、その窓を前に出してから選ぶ。
//  窓の実体は TabManager が持っていない（持ち主は SwiftUI）ので、
//  タブの WebView が載っている NSWindow を借りる——
//  全タブは ZStack に常時マウントされているので、必ず窓に載っている。
//

import AppKit
import Foundation
import SwiftUI

// MARK: - 探した結果の一件

struct TabSearchMatch: Identifiable {
    let id: UUID            // タブID。飛ぶ時の鍵になる
    let title: String
    let url: String
    let host: String
    let isPinned: Bool
    // 絵札。タブが既に持っているものをそのまま借りる——
    // ここから取りに行かせると、一覧を開いただけで
    // 全タブ分の通信が飛ぶ
    let favicon: NSImage?
    // 今いる窓のタブか。真なら一覧の上の方に並び、窓の名前も出さない
    let isCurrentWindow: Bool
    let windowLabel: String
}

// MARK: - 探す

enum TabSearch {
    // 一覧に並べる上限。
    // これを越える枚数を目で追うことはないし、
    // 越えたなら打ち込んで絞る方が早い
    static let limit = 60

    @MainActor
    static func matches(query: String, from current: TabManager) -> [TabSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        var mine: [TabSearchMatch] = []
        var others: [TabSearchMatch] = []

        // 普通の窓とプライベートウィンドウは互いに見えない。
        // プライベートで開いたページの題名が普通の窓の一覧に並べば、
        // それだけで「跡を残さない」という話が崩れる
        for manager in TabManager.openWindows where manager.isPrivate == current.isPrivate {
            let isCurrent = manager === current
            let label = manager.windowLabel
            // displayOrder を歩くのは、一覧の並びを画面の並びと揃えるためだ。
            // tabs を直に歩くと、グループ表示中に飛び飛びに見える
            for tab in manager.displayOrder {
                let title = tab.pageTitle.isEmpty
                    ? String(localized: "New Tab")
                    : tab.pageTitle
                let url = tab.urlText

                // 打ち込みが空なら全部出す。
                // ⇧⌘A を押して ↑↓ だけで選ぶ使い方ができる
                if !needle.isEmpty {
                    let hit = title.lowercased().contains(needle)
                        || url.lowercased().contains(needle)
                    guard hit else { continue }
                }

                let match = TabSearchMatch(
                    id: tab.id,
                    title: title,
                    url: url,
                    host: URL(string: url)?.host() ?? "",
                    isPinned: tab.isPinned,
                    favicon: tab.favicon,
                    isCurrentWindow: isCurrent,
                    windowLabel: label
                )
                if isCurrent { mine.append(match) } else { others.append(match) }
            }
        }

        // 自分の窓を先に。sort を使わないのは Swift の並べ替えが
        // 安定である保証を持たないからだ——仕分けてから繋ぐ方が確実で速い
        return Array((mine + others).prefix(limit))
    }
}

// MARK: - 打ち込み欄

// アドレスバー・ページ内検索と同じ土台（ClickSelectTextField）を使う。
// macOS 26 の SwiftUI TextField は AppKit の階層に現れず、
// 焦点の出し入れをこちらから握れない。
//
// Return で決定、↑↓ で選び、Esc で閉じる
struct TabSearchField: NSViewRepresentable {
    @Binding var text: String
    // 値が変わったら焦点を移して全選択する（⇧⌘A のたびに増える）
    let focusTrigger: Int
    let onSubmit: () -> Void
    let onMove: (Int) -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClickSelectTextField {
        let field = ClickSelectTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator

        let size: CGFloat = 13
        let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        let font = serif.flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        field.font = font
        field.textColor = NSColor(Deco.cream)
        field.placeholderAttributedString = NSAttributedString(
            string: String(localized: "Search open tabs"),
            attributes: [.foregroundColor: NSColor(Deco.dimGold), .font: font]
        )
        return field
    }

    func updateNSView(_ field: ClickSelectTextField, context: Context) {
        context.coordinator.parent = self
        // 編集中の打鍵を潰さないよう、編集していないときだけ外の値を反映する
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { field.focusAndSelectAll() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabSearchField
        var lastFocusTrigger: Int

        init(_ parent: TabSearchField) {
            self.parent = parent
            // 出た瞬間に焦点が欲しい。現在値と違う値から始めて、
            // 最初の updateNSView で必ず焦点合わせを走らせる（FindField と同じ手）
            self.lastFocusTrigger = parent.focusTrigger - 1
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - 盤

// 窓いっぱいに暗幕を張って、その真ん中に出す。
// シートにしないのは、⇧⌘A で開いて Esc で消えるまでの往復を
// できるだけ軽くしたいからだ（シートは出入りに間がある）
struct TabSearchPanel: View {
    @ObservedObject var manager: TabManager

    @State private var query = ""
    @State private var selection = 0

    private var matches: [TabSearchMatch] {
        TabSearch.matches(query: query, from: manager)
    }

    var body: some View {
        ZStack {
            // 暗幕。押せば閉じる
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            panel
                .frame(width: 560)
                .background(Deco.ink)
                .overlay(Rectangle().stroke(Deco.gold, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 20, y: 8)
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchRow
            Zigzag(teeth: 26)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(height: 5)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            list
        }
        .padding(.vertical, 16)
    }

    // ── 見出し ──

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Deco.gold)
            Text("Search Tabs")
                .font(.system(size: 12, design: .serif))
                .tracking(3)
                .foregroundColor(Deco.cream)
            Spacer()
            Text(verbatim: "\(matches.count)")
                .font(.system(size: 11, design: .serif))
                .foregroundColor(Deco.dimGold)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // ── 打ち込み欄 ──

    private var searchRow: some View {
        TabSearchField(
            text: $query,
            focusTrigger: manager.tabSearchFocusTrigger,
            onSubmit: submit,
            onMove: move,
            onCancel: close
        )
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Hexagon(inset: 6).fill(Deco.field))
        .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // ── 一覧 ──

    @ViewBuilder
    private var list: some View {
        if matches.isEmpty {
            Text("No matching tabs")
                .font(.system(size: 12, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.dimGold)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            row(index, match).id(match.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 340)
                // ↑↓ で選んだ行が幕の外へ出ないよう追いかける
                .onChange(of: selection) { _, index in
                    guard matches.indices.contains(index) else { return }
                    proxy.scrollTo(matches[index].id, anchor: .center)
                }
            }
        }
    }

    private func row(_ index: Int, _ match: TabSearchMatch) -> some View {
        let isSelected = index == selection
        return HStack(spacing: 10) {
            // 帯と同じ絵札。枠が金ならピン留め
            FaviconBadge(image: match.favicon, isPinned: match.isPinned, side: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: match.title)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(isSelected ? Deco.cream : Deco.gold)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !match.host.isEmpty {
                    Text(verbatim: match.host)
                        .font(.system(size: 10, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.dimGold)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 別の窓に居る場合だけ、どの窓かを添える。
            // 今いる窓の分にまで付けると、九割の行に同じ札が並ぶ
            if !match.isCurrentWindow {
                Text(verbatim: match.windowLabel)
                    .font(.system(size: 9, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Deco.gold.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        // Button ではなく onTapGesture なのは、押した拍子に
        // first responder が打ち込み欄から奪われるのを避けるためだ
        //（アドレスバーの候補一覧と同じ判断）
        .onTapGesture { activate(match) }
        .onHover { inside in
            if inside { selection = index }
        }
    }

    // ── 操作 ──

    private func submit() {
        guard matches.indices.contains(selection) else { return }
        activate(matches[selection])
    }

    private func activate(_ match: TabSearchMatch) {
        close()
        TabManager.reveal(tabID: match.id)
    }

    // ↑↓。端まで来たら巻き戻す（候補一覧と同じ流儀）
    private func move(_ offset: Int) -> Bool {
        let count = matches.count
        guard count > 0 else { return true }
        selection = ((selection + offset) % count + count) % count
        return true
    }

    private func close() {
        manager.isTabSearchVisible = false
    }
}
