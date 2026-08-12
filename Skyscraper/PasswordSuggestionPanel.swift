//
//  PasswordSuggestionPanel.swift
//  Skyscraper
//
//  入力欄の脇に出す、預かりの一覧。
//
//  なぜ小窓（NSPanel）なのか：
//
//  ページの DOM に描くと、そのサイトの JS から利用者名を読めてしまう。
//  ログインする前に「この人はどの口座を持っているか」を教える筋合いは無い。
//  偽の click を投げて記入を起こす道も開く。
//
//  SwiftUI を WKWebView の上に重ねる手も、AppKit との重なり順が
//  当てにならない（サジェストの一覧で一度踏んでいる）。
//  別の窓にすれば、どちらの話も最初から起きない。
//
//  非活性の小窓（.nonactivatingPanel）にしてあるのが肝で、
//  これを怠ると小窓を押した拍子に入力欄が焦点を失い、
//  blur → 一覧を畳む → 押した先が消える、の順で何も起きなくなる。
//

import AppKit
import SwiftUI

@MainActor
final class PasswordSuggestionPanel {
    static let shared = PasswordSuggestionPanel()

    private var panel: NSPanel?
    private var monitor: Any?

    private init() {}

    var isVisible: Bool { panel != nil }

    // anchor は画面座標での入力欄の外枠（高さも含む）。
    // 上へ返す時に欄の上端が要るので、高さを潰して渡してはいけない
    func show(logins: [SavedLogin],
              anchoredTo anchor: NSRect,
              in parent: NSWindow,
              onPick: @escaping (SavedLogin) -> Void) {
        hide()
        guard !logins.isEmpty else { return }

        let list = PasswordSuggestionList(logins: logins) { [weak self] login in
            self?.hide()
            onPick(login)
        }

        let hosting = NSHostingView(rootView: list)
        // 入力欄より狭いと見窄らしいので、欄の幅を下限にする
        let minimum = max(anchor.width, 200)
        hosting.frame.size = hosting.fittingSize
        let size = NSSize(width: max(hosting.fittingSize.width, minimum),
                          height: hosting.fittingSize.height)
        hosting.frame.size = size

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = false
        panel.animationBehavior = .utilityWindow

        panel.setFrameOrigin(Self.origin(for: size, anchor: anchor, within: Self.bounds(of: parent)))
        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel

        // 余所を押されたら、Esc が来たら畳む。
        // ページ側の scroll と blur からも畳む知らせが届くが、
        // アプリの他の部分を触られた場合はそちらには流れてこない
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // 53 は Esc
                if event.keyCode == 53 {
                    self.hide()
                    return nil
                }
                return event
            }
            if event.window !== self.panel {
                self.hide()
            }
            return event
        }
    }

    func hide() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    // 収まるべき枠。
    //
    // 画面ではなく窓を基準にするのが肝で、画面の端で測ると、
    // 窓が画面の途中にある限り「まだ下に余地がある」と判断され、
    // 一覧が窓の下へはみ出したまま返らない。
    // 画面との共通部分を採るのは、窓が画面外へ押し出されている時のため
    private static func bounds(of parent: NSWindow) -> NSRect {
        guard let visible = parent.screen?.visibleFrame else { return parent.frame }
        let shared = parent.frame.intersection(visible)
        return shared.isEmpty ? visible : shared
    }

    // 入力欄の真下に置く。入らなければ欄の上へ返す。
    //
    // 窓や画面を持ち込まない純粋な計算にしてあるのは、
    // 座標の上下が入れ替わる話なので、机上で確かめられるようにするため
    static func origin(for size: NSSize, anchor: NSRect, within bounds: NSRect) -> NSPoint {
        let margin: CGFloat = 4
        let gap: CGFloat = 2

        // 横：枠からはみ出さないところまで寄せる
        let maxX = max(bounds.minX + margin, bounds.maxX - size.width - margin)
        let x = min(max(anchor.minX, bounds.minX + margin), maxX)

        // 縦：既定は欄の下（画面座標は上向きなので、下＝小さい y）
        let below = anchor.minY - size.height - gap
        if below >= bounds.minY + margin {
            return NSPoint(x: x, y: below)
        }

        // 下に入らない。欄の上へ返す
        let above = anchor.maxY + gap
        if above + size.height <= bounds.maxY - margin {
            return NSPoint(x: x, y: above)
        }

        // 上下どちらにも収まらない（極端に狭い窓）。広い側へ寄せて詰める
        let roomBelow = anchor.minY - bounds.minY
        let roomAbove = bounds.maxY - anchor.maxY
        let y = roomAbove > roomBelow
            ? bounds.maxY - size.height - margin
            : bounds.minY + margin
        return NSPoint(x: x, y: y)
    }
}

// MARK: - 中身

private struct PasswordSuggestionList: View {
    let logins: [SavedLogin]
    let onPick: (SavedLogin) -> Void

    @State private var hovered: SavedLogin?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 9))
                Text("Saved Passwords")
                    .font(.system(size: 9, design: .serif))
                    .tracking(1)
            }
            .foregroundColor(Deco.dimGold)
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 5)

            ForEach(logins) { login in
                Rectangle()
                    .fill(Deco.faintGold.opacity(0.4))
                    .frame(height: 1)

                HStack(spacing: 8) {
                    Text(verbatim: login.username.isEmpty
                         ? String(localized: "(no user name)")
                         : login.username)
                        .font(.system(size: 12, design: .serif))
                        .foregroundColor(hovered == login ? Deco.cream : Deco.gold)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(verbatim: login.origin)
                        .font(.system(size: 9, design: .serif))
                        .foregroundColor(Deco.dimGold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(hovered == login ? Deco.gold.opacity(0.18) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { onPick(login) }
                .onHover { inside in hovered = inside ? login : nil }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .background(Deco.panel2)
        .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1))
    }
}
