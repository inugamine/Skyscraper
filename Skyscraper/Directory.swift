//
//  Directory.swift
//  Skyscraper
//
//  館内案内板 (⌘K)。ロビーの金文字の案内板を模した、何でも引ける盤。
//
//  ── 階 ──
//  L  ロビー        全部の階を串刺しで見る (各階の上から数件ずつ)
//  1F 開いているタブ  全ての窓のタブ。並びと絞り込みはタブ検索 (⇧⌘A) と同じ
//  2F ブックマーク    棚のブックマーク。開くのは今のタブ (アドレスバーの候補と同じ)
//  3F 操作          メニューにある操作を中心に、今のタブで意味のある物だけ
//  4F 最近閉じたタブ  ⇧⌘T の控えを新しい順に。選んだ一枚を開き直す
//
//  階はエレベーターの押しボタンで選ぶ。Tab で次の階、⇧Tab で前の階。
//
//  ── 盤の土台 ──
//  暗幕・打ち込み欄・ジグザグ罫はタブ検索の盤 (TabSearch.swift) と同じ作り。
//  打ち込み欄そのものも TabSearchField を借りている。
//  ⇧⌘A はタブだけを探す道具として残してある (Safari と同じ位置)
//

import AppKit
import SwiftUI
import WebKit

// MARK: - 階

enum DirectoryFloor: Int, CaseIterable, Identifiable {
    case lobby, tabs, bookmarks, actions, closed

    var id: Int { rawValue }

    // 押しボタンの刻印
    var buttonLabel: String { self == .lobby ? "L" : "\(rawValue)" }

    // 見出しの階表示
    var floorLabel: String { self == .lobby ? "L" : "\(rawValue)F" }

    var name: String {
        switch self {
        case .lobby:     String(localized: "All Floors")
        case .tabs:      String(localized: "Open Tabs")
        case .bookmarks: String(localized: "Bookmarks")
        case .actions:   String(localized: "Actions")
        case .closed:    String(localized: "Recently Closed")
        }
    }

    // ロビー以外の階 (下から順に)
    static var floors: [DirectoryFloor] { [.tabs, .bookmarks, .actions, .closed] }
}

// MARK: - 一件

struct DirectoryEntry: Identifiable {
    let id: String
    let floor: DirectoryFloor
    let title: String
    var detail: String = ""
    var symbol: String? = nil
    // タブの行だけ、帯と同じ絵札を出す
    var showsFavicon = false
    var favicon: NSImage? = nil
    var isPinned = false
    // 操作の行の右端に添えるキー
    var shortcut: String? = nil
    // 別の窓のタブの行の右端に添える窓の名前
    var badge: String? = nil
    // 表示の文言とは別に引っかけたい語。
    // 操作は英語の名前も持たせる——日本語の画面で "reader" と打っても出るように
    var keywords: [String] = []
    let perform: @MainActor () -> Void

    func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return ([title, detail] + keywords).contains { $0.lowercased().contains(needle) }
    }
}

// 一つの階ぶんの束
struct DirectorySection: Identifiable {
    let floor: DirectoryFloor
    let entries: [DirectoryEntry]
    var id: Int { floor.rawValue }
}

// MARK: - 名簿を組む

@MainActor
struct DirectoryContext {
    let manager: TabManager
    let bookmarks: BookmarkStore
    let translator: Translator?
    let openSettings: () -> Void
}

@MainActor
enum Directory {
    // ロビーで一つの階から見せる件数。
    // それ以上は、その階のボタンを押して見ればいい
    static let lobbyLimit = 5
    // 一つの階で見せる上限。越えたなら打ち込んで絞る方が早い
    static let floorLimit = 80

    static func sections(floor: DirectoryFloor,
                         query: String,
                         context: DirectoryContext) -> [DirectorySection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if floor == .lobby {
            return DirectoryFloor.floors.compactMap { f in
                let list = Array(entries(on: f, needle: needle, query: query, context: context)
                    .prefix(lobbyLimit))
                return list.isEmpty ? nil : DirectorySection(floor: f, entries: list)
            }
        }
        let list = Array(entries(on: floor, needle: needle, query: query, context: context)
            .prefix(floorLimit))
        return list.isEmpty ? [] : [DirectorySection(floor: floor, entries: list)]
    }

    private static func entries(on floor: DirectoryFloor,
                                needle: String,
                                query: String,
                                context: DirectoryContext) -> [DirectoryEntry] {
        switch floor {
        case .lobby:     return []
        case .tabs:      return tabs(query: query, context: context)
        case .bookmarks: return bookmarks(context).filter { $0.matches(needle) }
        case .actions:   return actions(context).filter { $0.matches(needle) }
        case .closed:    return closed(context).filter { $0.matches(needle) }
        }
    }

    // ── 1F 開いているタブ ──
    // 絞り込みはタブ検索に任せる。同じ打ち込みで同じ結果が出るように
    private static func tabs(query: String, context: DirectoryContext) -> [DirectoryEntry] {
        TabSearch.matches(query: query, from: context.manager).map { match in
            DirectoryEntry(id: "tab:\(match.id.uuidString)",
                           floor: .tabs,
                           title: match.title,
                           detail: match.host,
                           showsFavicon: true,
                           favicon: match.favicon,
                           isPinned: match.isPinned,
                           badge: match.isCurrentWindow ? nil : match.windowLabel,
                           perform: { TabManager.reveal(tabID: match.id) })
        }
    }

    // ── 2F ブックマーク ──
    private static func bookmarks(_ context: DirectoryContext) -> [DirectoryEntry] {
        let manager = context.manager
        return context.bookmarks.bookmarks.map { bookmark in
            let host = URL(string: bookmark.url)?.host() ?? ""
            let folders = (bookmark.folder ?? []).joined(separator: " › ")
            let detail = [folders, host].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            return DirectoryEntry(id: "bookmark:\(bookmark.id.uuidString)",
                                  floor: .bookmarks,
                                  title: bookmark.title,
                                  detail: detail,
                                  symbol: "star",
                                  keywords: [bookmark.url],
                                  perform: {
                                      if let tab = manager.selectedTab {
                                          tab.open(bookmark: bookmark.url)
                                      } else {
                                          manager.addTab(url: bookmark.url)
                                      }
                                  })
        }
    }

    // ── 4F 最近閉じたタブ ──
    private static func closed(_ context: DirectoryContext) -> [DirectoryEntry] {
        let manager = context.manager
        return manager.recentlyClosedTabs.enumerated().map { index, record in
            let host = URL(string: record.url)?.host() ?? ""
            let title = !record.title.isEmpty ? record.title
                : (record.url.isEmpty ? String(localized: "New Tab") : record.url)
            return DirectoryEntry(id: "closed:\(index)",
                                  floor: .closed,
                                  title: title,
                                  detail: host,
                                  symbol: "arrow.uturn.backward",
                                  keywords: [record.url],
                                  perform: { manager.reopenClosed(newestIndex: index) })
        }
    }

    // ── 3F 操作 ──
    //
    // 文言はメニューと同じ鍵を使う。訳が既にあるものはそのまま効く
    private static func action(_ title: LocalizedStringResource,
                               id: String? = nil,
                               symbol: String,
                               shortcut: String? = nil,
                               perform: @escaping @MainActor () -> Void) -> DirectoryEntry {
        DirectoryEntry(id: "action:" + (id ?? title.key),
                       floor: .actions,
                       title: String(localized: title),
                       symbol: symbol,
                       shortcut: shortcut,
                       keywords: [title.key],
                       perform: perform)
    }

    private static func themeName(_ theme: DecoTheme) -> String {
        switch theme {
        case .blackGold:     String(localized: "Black & Gold")
        case .verdigrisGold: String(localized: "Verdigris & Gold")
        }
    }

    private static func actions(_ context: DirectoryContext) -> [DirectoryEntry] {
        let manager = context.manager
        let tab = manager.selectedTab
        // ロビー (新規タブの盤) ではページに働きかける操作を出さない
        let page = (tab?.isHome == false) ? tab : nil
        var list: [DirectoryEntry] = []

        list.append(action("New Tab", symbol: "plus.square", shortcut: "⌘T") {
            manager.addTab()
        })
        list.append(action("New Private Window", symbol: "eye.slash", shortcut: "⇧⌘N") {
            manager.openPrivateWindow()
        })

        if let tab {
            // ピン留めしたタブは ⌘W と同じく閉じない
            if !tab.isPinned {
                list.append(action("Close Tab", symbol: "xmark.square", shortcut: "⌘W") {
                    manager.closeSelected()
                })
            }
            if tab.isPinned {
                list.append(action("Unpin Tab", symbol: "pin.slash") { manager.togglePin(tab) })
            } else {
                list.append(action("Pin Tab", symbol: "pin") { manager.togglePin(tab) })
            }
            list.append(action("Move Tab to New Window", symbol: "macwindow.badge.plus") {
                manager.moveSelectedTabToNewWindow()
            })
        }

        if let page {
            if page.isMuted {
                list.append(action("Unmute Tab", symbol: "speaker.wave.2") { page.toggleMute() })
            } else {
                list.append(action("Mute Tab", symbol: "speaker.slash") { page.toggleMute() })
            }
            if page.isReaderAvailable || page.isReaderActive {
                if page.isReaderActive {
                    list.append(action("Hide Reader", symbol: "book.fill") { page.toggleReader() })
                } else {
                    list.append(action("Show Reader", symbol: "book") { page.toggleReader() })
                }
            }
            if page.isFloating {
                list.append(action("Return Floating Tab", symbol: "pip.exit", shortcut: "⌥⌘P") {
                    FloatingPlayer.shared.returnToTab(reveal: true)
                })
            } else {
                list.append(action("Float Tab", symbol: "pip.enter", shortcut: "⌥⌘P") {
                    FloatingPlayer.shared.toggle(page, in: manager)
                })
            }
            list.append(action("Find…", symbol: "magnifyingglass", shortcut: "⌘F") {
                page.showFindBar()
            })
            if let translator = context.translator {
                list.append(action("Translate Selection…", symbol: "character.book.closed",
                                   shortcut: "⌥⌘T") {
                    translator.translateSelection(in: page.webView)
                })
            }
            list.append(action("Copy Clean Link", symbol: "link", shortcut: "⇧⌘C") {
                CleanLink.copyPage(of: page)
            })
            list.append(action("Reload", symbol: "arrow.clockwise", shortcut: "⌘R") {
                page.reload()
            })
            list.append(action("Reload Without Cache", symbol: "arrow.clockwise.circle",
                               shortcut: "⇧⌘R") {
                page.reloadFromOrigin()
            })
            list.append(action("Zoom In", symbol: "plus.magnifyingglass", shortcut: "⌘+") {
                page.zoomIn()
            })
            list.append(action("Zoom Out", symbol: "minus.magnifyingglass", shortcut: "⌘−") {
                page.zoomOut()
            })
            list.append(action("Actual Size", symbol: "1.magnifyingglass", shortcut: "⌘0") {
                page.zoomReset()
            })
            list.append(action("Save Page As…", symbol: "square.and.arrow.down", shortcut: "⌘S") {
                PageExporter.savePage(page)
            })
            list.append(action("Export as PDF…", symbol: "doc.richtext") {
                PageExporter.exportPDF(page)
            })
            list.append(action("Print…", symbol: "printer", shortcut: "⌘P") {
                PageExporter.print(page)
            })
        }

        // ブックマークバー。鍵はメニューの Toggle (BrowserCommands) と同じ
        let barKey = "bookmarkBarVisible"
        let barVisible = UserDefaults.standard.object(forKey: barKey) as? Bool ?? true
        if barVisible {
            list.append(action("Hide Bookmarks Bar", symbol: "bookmark.slash", shortcut: "⌘B") {
                UserDefaults.standard.set(false, forKey: barKey)
            })
        } else {
            list.append(action("Show Bookmarks Bar", symbol: "bookmark", shortcut: "⌘B") {
                UserDefaults.standard.set(true, forKey: barKey)
            })
        }

        // ダウンロードの棚。今回の起動で何か落としていれば
        let downloads = DownloadManager.shared
        if !downloads.items.isEmpty {
            if downloads.isShelfVisible {
                list.append(action("Hide Downloads", symbol: "arrow.down.circle.fill") {
                    downloads.isShelfVisible = false
                })
            } else {
                list.append(action("Show Downloads", symbol: "arrow.down.circle") {
                    downloads.isShelfVisible = true
                })
            }
        }

        let bookmarks = context.bookmarks
        list.append(action("Import Bookmarks…", symbol: "square.and.arrow.down.on.square") {
            BookmarkImport.chooseFile(into: bookmarks)
        })
        list.append(action("Export Bookmarks…", symbol: "square.and.arrow.up.on.square") {
            BookmarkExport.chooseFile(from: bookmarks)
        })

        // 配色。今の配色以外を並べる
        let current = DecoThemeStore.shared.theme
        for theme in DecoTheme.allCases where theme != current {
            let name = themeName(theme)
            list.append(action("Switch to \(name)", id: "theme:" + theme.rawValue,
                               symbol: "paintpalette") {
                DecoThemeStore.shared.theme = theme
            })
        }

        list.append(action("Search Tabs…", symbol: "rectangle.stack", shortcut: "⇧⌘A") {
            manager.showTabSearch()
        })
        let openSettings = context.openSettings
        list.append(action("Settings…", symbol: "gearshape", shortcut: "⌘,") {
            openSettings()
        })
        return list
    }
}

// MARK: - 盤

struct DirectoryPanel: View {
    @ObservedObject var manager: TabManager
    let translator: Translator?

    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var floor: DirectoryFloor = .lobby
    @State private var selection = 0
    // 選んだ行を追いかけてスクロールするか。↑↓ で選んだ時だけ立てる。
    // カーソルが乗った行も選ばれるが、そちらでまで追いかけると
    // スクロール→カーソルの下に別の行→選び直し→スクロール…と喧嘩する
    @State private var followsSelection = false

    private var context: DirectoryContext {
        DirectoryContext(manager: manager,
                         bookmarks: bookmarks,
                         translator: translator,
                         openSettings: { openSettings() })
    }

    var body: some View {
        let sections = Directory.sections(floor: floor, query: query, context: context)
        let flat = sections.flatMap(\.entries)

        ZStack {
            // 暗幕。押せば閉じる
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 0) {
                header
                searchRow(flat)
                Zigzag(teeth: 28)
                    .stroke(Deco.faintGold, lineWidth: 1)
                    .frame(height: 5)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                list(sections, flat: flat)
            }
            .padding(.vertical, 16)
            .frame(width: 600)
            .background(Deco.ink)
            .overlay(Rectangle().stroke(Deco.gold, lineWidth: 1))
            .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1).padding(-5))
            .shadow(color: .black.opacity(0.6), radius: 20, y: 8)
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: floor) { _, _ in selection = 0 }
    }

    // ── 見出しと押しボタン ──

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DIRECTORY")
                    .font(.system(size: 13, design: .serif))
                    .tracking(4)
                    .foregroundColor(Deco.cream)
                Text(verbatim: "\(floor.floorLabel)  ·  \(floor.name.uppercased())")
                    .font(.system(size: 10, design: .serif))
                    .tracking(2)
                    .foregroundColor(Deco.dimGold)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(DirectoryFloor.allCases) { f in
                    floorButton(f)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    // エレベーターの押しボタン。今いる階だけ金に灯る
    private func floorButton(_ f: DirectoryFloor) -> some View {
        let isCurrent = f == floor
        return Text(verbatim: f.buttonLabel)
            .font(.system(size: 11, design: .serif))
            .foregroundColor(isCurrent ? Deco.ink : Deco.gold)
            .frame(width: 24, height: 24)
            .background(Circle().fill(isCurrent ? Deco.gold : Color.clear))
            .overlay(Circle().stroke(isCurrent ? Deco.gold : Deco.faintGold, lineWidth: 1))
            .contentShape(Circle())
            // Button にしないのは、押した拍子に打ち込み欄から焦点を奪わないため
            .onTapGesture { floor = f }
            .help(f.name)
    }

    // ── 打ち込み欄 ──

    private func searchRow(_ flat: [DirectoryEntry]) -> some View {
        TabSearchField(
            text: $query,
            focusTrigger: manager.directoryFocusTrigger,
            onSubmit: { submit(flat) },
            onMove: { move($0, count: flat.count) },
            onCancel: close,
            placeholder: String(localized: "Search the directory"),
            onTab: changeFloor
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
    private func list(_ sections: [DirectorySection],
                      flat: [DirectoryEntry]) -> some View {
        if flat.isEmpty {
            Group {
                if query.isEmpty {
                    Text("Nothing on this floor")
                } else {
                    Text("No matches")
                }
            }
                .font(.system(size: 12, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.dimGold)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            // ロビーでだけ階の見出しを出す。
                            // 一つの階を見ている時は、上の見出しが同じことを言っている
                            if floor == .lobby {
                                floorHeading(section.floor)
                            }
                            let offset = sections.prefix(sectionIndex).reduce(0) { $0 + $1.entries.count }
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                row(offset + index, entry).id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 380)
                // ↑↓ で選んだ行が幕の外へ出ないよう追いかける。
                // 位置を指定しないのは、見えている行なら動かさず、
                // 外へ出かけた時だけ最小限ずらしたいから
                .onChange(of: selection) { _, index in
                    guard followsSelection else { return }
                    followsSelection = false
                    guard flat.indices.contains(index) else { return }
                    proxy.scrollTo(flat[index].id)
                }
            }
        }
    }

    private func floorHeading(_ f: DirectoryFloor) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 5))
                .foregroundColor(Deco.gold)
            Text(verbatim: f.floorLabel)
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.gold)
                .frame(width: 20, alignment: .leading)
            Text(verbatim: f.name.uppercased())
                .font(.system(size: 10, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.dimGold)
            Rectangle().fill(Deco.faintGold).frame(height: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func row(_ index: Int, _ entry: DirectoryEntry) -> some View {
        let isSelected = index == selection
        return HStack(spacing: 10) {
            if entry.showsFavicon {
                FaviconBadge(image: entry.favicon, isPinned: entry.isPinned, side: 18)
            } else {
                Image(systemName: entry.symbol ?? "circle")
                    .font(.system(size: 12))
                    .foregroundColor(Deco.gold)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(isSelected ? Deco.cream : Deco.gold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !entry.detail.isEmpty {
                    Text(verbatim: entry.detail)
                        .font(.system(size: 10, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.dimGold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let badge = entry.badge {
                Text(verbatim: badge)
                    .font(.system(size: 9, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 0.5))
            } else if let shortcut = entry.shortcut {
                Text(verbatim: shortcut)
                    .font(.system(size: 10, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.dimGold)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Deco.gold.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        // Button ではなく onTapGesture なのは、タブ検索と同じ理由
        // (押した拍子に打ち込み欄から焦点を奪わない)
        .onTapGesture { activate(entry) }
        .onHover { inside in
            if inside { selection = index }
        }
    }

    // ── 操作 ──

    private func submit(_ flat: [DirectoryEntry]) {
        guard flat.indices.contains(selection) else { return }
        activate(flat[selection])
    }

    // 盤を畳んでから実行する。
    // 盤が出たままだと、ページ内検索などが焦点を受け取れない
    private func activate(_ entry: DirectoryEntry) {
        close()
        DispatchQueue.main.async { entry.perform() }
    }

    // ↑↓。端まで来たら巻き戻す (タブ検索と同じ流儀)
    private func move(_ offset: Int, count: Int) -> Bool {
        guard count > 0 else { return true }
        followsSelection = true
        selection = ((selection + offset) % count + count) % count
        return true
    }

    // Tab / ⇧Tab で階を移る。上の階の先は L へ戻る
    private func changeFloor(_ offset: Int) -> Bool {
        let all = DirectoryFloor.allCases
        let count = all.count
        let next = ((floor.rawValue + offset) % count + count) % count
        floor = all[next]
        return true
    }

    private func close() {
        manager.isDirectoryVisible = false
    }
}
