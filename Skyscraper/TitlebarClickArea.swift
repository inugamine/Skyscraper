//
//  TitlebarClickArea.swift
//  Skyscraper
//
//  透かしたタイトルバーで、ダブルクリックの拡大/縮小を取り戻す。
//
//  ContentView で帯の背景を消すと (toolbarBackgroundVisibility(.hidden))、
//  帯の空いた所のダブルクリックが効かなくなり、題名の文字の上でしか窓が広がらない。
//  板を敷いて受ける手は通らなかった (クリックがどこへ落ちているのか、外からは掴めない) ので、
//  窓に届くマウス押下を手前で見張り、帯の上のダブルクリックだけを拾って窓へ渡す。
//
//  信号機のボタンと題名の文字は今でも自前で受けるので、そこに当たった分は手を出さない
//  (出すと拡大が二度走って元に戻ってしまう)
//

import SwiftUI
import AppKit

struct TitlebarClickArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarClickView { TitlebarClickView() }
    func updateNSView(_ nsView: TitlebarClickView, context: Context) {}
}

final class TitlebarClickView: NSView {
    private var monitor: Any?

    // 窓を知るためだけの目印。クリックは一切受けない
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // 見張りはメインで呼ばれる。NSEvent は Sendable ではないので、
            // 要る値だけ抜いてから MainActor の側へ渡す
            let clicks = event.clickCount
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            let handled = MainActor.assumeIsolated {
                self?.handleDoubleClick(clicks: clicks, windowNumber: windowNumber, at: location) ?? false
            }
            // 拾った分は飲み込む。それ以外はそのまま流す
            return handled ? nil : event
        }
    }

    // 帯の上のダブルクリックなら窓へ渡して true を返す
    private func handleDoubleClick(clicks: Int, windowNumber: Int, at location: NSPoint) -> Bool {
        guard clicks == 2,
              let window,
              window.windowNumber == windowNumber,
              // 帯は中身の領域より上 (窓の座標は左下が原点)
              location.y >= window.contentLayoutRect.maxY else { return false }

        // 帯の上で実際に当たる部品を引く。ボタンと題名は自前で受けるので任せる
        if let frameView = window.contentView?.superview,
           let hit = frameView.hitTest(frameView.convert(location, from: nil)),
           hit is NSButton || hit is NSTextField {
            return false
        }

        performDoubleClickAction(on: window)
        return true
    }

    // システム設定の「ウインドウのタイトルバーをダブルクリックして…」に従う。
    // 値は全体の設定 (NSGlobalDomain) にあり、standard から読める
    private func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            // "Maximize" (拡大/縮小) と未設定はこれ。
            // "Fill" (画面いっぱい) を外から呼ぶ公開 API は無いので、拡大/縮小で代える。
            // 標準の大きさは画面の使える範囲いっぱいなので、見た目はほぼ同じになる
            window.performZoom(nil)
        }
    }
}
