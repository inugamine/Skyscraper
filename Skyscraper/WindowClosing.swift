//
//  WindowClosing.swift
//  Skyscraper
//
//  窓を閉じる前の確認 (⇧⌘W) と、閉じた窓の控え (⇧⌘T で開き直す)。
//
//  ── 控えはメモリにだけ置く ──
//  閉じたタブの控え (TabManager.recentlyClosed) と同じで、ディスクには書かない。
//  アプリを終えれば消える。終了をまたいで戻すのはセッション復元の仕事だ。
//  ここに書き出しを足すと、「閉じた」はずの窓の URL と履歴が
//  利用者の知らない所に残り続けることになる
//
//  ── 確認の盤は NSAlert のまま ──
//  JSDialog.swift と同じ方針。ブラウザ自身が出す問いは、
//  ブラウザ自身のものだと一目で判る形で出す
//
//  ── 赤い丸 (閉じるボタン) では訊かない ──
//  訊くのは ⇧⌘W だけ。赤い丸の行き先は SwiftUI が握っている窓の代理人で、
//  そこへ割り込むには窓の delegate を差し替えることになる。
//  控えの方は onDisappear で積むので、どちらで閉じても ⇧⌘T で戻る
//

import AppKit
// ObservableObject と @Published の出所。
// AppKit 越しには見えない (モジュールの中身は明示的に import した分しか使えない設定)
import Combine

// 閉じたタブ一枚ぶんの控え。
// interactionState には戻る／進むの履歴が丸ごと入っているので、
// 開き直したタブでそのまま戻れる。
//
// 以前は TabManager の中に private で居たが、閉じた窓の控えも
// 同じ形のタブを抱えるので、外へ出して共用する
struct ClosedTab {
    var url: String        // 空文字はロビー
    var title: String
    var interactionState: Data?
    // どのプロファイルのタブだったか。開き直した時に同じ置き場へ戻す
    var profile: UUID?
    // ピン留めしてあったか。窓ごと戻す時にだけ見る
    // (タブ一枚を戻す reopenClosed は今まで通り留めずに開く)
    var pinned: Bool = false
    // 閉じた時刻。⇧⌘T が「タブと窓のどちらを後に閉じたか」を比べるのに使う
    var closedAt = Date()
}

// 閉じた窓一枚ぶんの控え
struct ClosedWindow {
    // 閉じた窓の名札 (TabManager.windowID)。
    // onDisappear の誤発火で積んだ控えを、戻ってきた本人が取り下げるのに使う
    let owner: UUID
    var tabs: [ClosedTab]
    var selectedIndex: Int
    var closedAt = Date()
}

// 閉じた窓の控えの置き場。アプリに一つ。
//
// 窓ごとの管理人に持たせないのは、持ち主の窓が閉じた後にこそ要るものだからだ。
// ObservableObject にしてあるのは、窓が一枚も無い時にメニューの
// 「Reopen Closed Tab」を押せるかどうかを、控えの有無で決めたいから
@MainActor
final class ClosedWindowStore: ObservableObject {
    static let shared = ClosedWindowStore()

    // 古い順。末尾が直近に閉じた窓
    @Published private(set) var windows: [ClosedWindow] = []

    // 控えの上限。閉じたタブ (20 件) より少なめにしてある——
    // 一件で数十枚のタブと、その全部の履歴を抱えることがある
    private static let limit = 10

    private init() {}

    var latest: ClosedWindow? { windows.last }

    func record(_ window: ClosedWindow) {
        // 同じ窓の控えが既にあれば差し替える (誤発火の後に本当に閉じられた場合)
        windows.removeAll { $0.owner == window.owner }
        windows.append(window)
        if windows.count > Self.limit {
            windows.removeFirst(windows.count - Self.limit)
        }
    }

    // 閉じたと思ったら戻ってきた (onDisappear の誤発火)。控えを引っ込める
    func withdraw(owner: UUID) {
        guard windows.contains(where: { $0.owner == owner }) else { return }
        windows.removeAll { $0.owner == owner }
    }

    func popLast() -> ClosedWindow? {
        windows.popLast()
    }

    // プロファイルを消した時に、そのプロファイルのタブを控えからも抜く。
    // 置き場ごと消すのに開き直す道を残すのは筋が通らない (TabManager.closeTabs と同じ)。
    // 抜いた結果ロビーしか残らない窓は、控えごと捨てる
    func forgetProfile(_ id: UUID) {
        guard windows.contains(where: { window in
            window.tabs.contains { $0.profile == id }
        }) else { return }

        windows = windows.compactMap { original in
            var window = original
            // 選んでいた一枚が消えるなら先頭へ、残るなら前に詰まった分だけずらす
            let selectedRemoved = window.tabs[safe: window.selectedIndex]?.profile == id
            let removedBefore = window.tabs.prefix(window.selectedIndex)
                .filter { $0.profile == id }.count
            window.tabs.removeAll { $0.profile == id }
            guard window.tabs.contains(where: { !$0.url.isEmpty || $0.interactionState != nil })
            else { return nil }
            window.selectedIndex = selectedRemoved ? 0 : window.selectedIndex - removedBefore
            return window
        }
    }
}

// ⇧⌘W の確認。
@MainActor
enum CloseWindowConfirmation {
    // 設定の「窓を閉じる前に確認する」。既定は有効。
    // 盤の「次回から確認しない」はこれを倒すだけなので、設定で入れ直せば元に戻る
    static let enabledKey = "skyscraper.confirmCloseWindow"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // 閉じてよければ真。確認を切ってあれば訊かずに真を返す。
    // canReopen が偽 (プライベートウィンドウ) なら、戻せないことを書き添える
    static func ask(in window: NSWindow, canReopen: Bool) async -> Bool {
        guard isEnabled else { return true }

        let alert = NSAlert()
        alert.alertStyle = canReopen ? .informational : .warning
        alert.messageText = String(localized: "Close this window?")
        alert.informativeText = canReopen
            ? String(localized: "All of its tabs will be closed. You can reopen the window with ⇧⌘T.")
            : String(localized: "All of its tabs will be closed and cannot be reopened.")
        alert.addButton(withTitle: String(localized: "Close Window"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        // 窓に貼り付ける (シート)。他の窓の操作は止めない
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        let closes = response == .alertFirstButtonReturn

        // 印を受け取るのは「閉じる」を押した時だけ。
        // 印を付けたまま取り消したなら、閉じるのをためらった人だ——
        // 次から黙って閉じられて一番困るのはその人になる
        if closes, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: enabledKey)
        }
        return closes
    }
}
