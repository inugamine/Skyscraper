//
//  JSDialog.swift
//  Skyscraper
//
//  alert() / confirm() / prompt() の受け皿。
//
//  WKUIDelegate にこの三つを実装しない限り、WebKit は問い合わせを黙って捨てる——
//  alert は何も出ず、confirm は常に false、prompt は常に null。
//  ページ側から見れば「押しても無反応」「必ず取り消した扱い」になる。
//  削除の確認、年齢確認、簡易入力を使っているページはこれで静かに壊れる。
//  ポップアップは必ず知らせて開き直せるようにしてあるのに、
//  ここだけ黙って捨てているのは筋が通らない。
//
//  出し方の作法：
//
//  ・見出しは「どのサイトが言っているか」、ページの文言は本文に置く。
//    出所はページの申告ではなく WebKit が握っている securityOrigin から取る。
//    ここを混ぜると、ページはいくらでもブラウザ自身の言葉を騙れる
//  ・意匠は NSAlert のまま（アール・デコで塗らない）。ブラウザの盤を
//    自前で描くと、ページ内に作られた偽の盤と見分けが付かなくなる。
//    利用者が「これはブラウザが出したもの」と判る形が、ここでは正しい
//  ・連打への逃げ道として抑制ボタンを添える。押された後は WebKit の
//    既定（何もしない／false／null）に倒す。ページを移れば仕切り直す
//

import Foundation
import AppKit
import WebKit

@MainActor
final class JSDialogPresenter {
    // このページではもう出さない（利用者が抑制ボタンを押した）。
    // 数を数えて自動で黙る作りにはしていない——
    // JS はこちらが答えるまで止まっているので、連打の速さには限りがあるし、
    // 何度目かで勝手に無視を始めると、それこそ「黙って捨てる」に戻る
    private var suppressed = false

    // 次のページへ移った。抑制は前のページ限りだ
    func reset() { suppressed = false }

    // MARK: - alert()

    func alert(message: String, host: String, in window: NSWindow?) async {
        guard !suppressed else { return }
        let alert = base(message: message, host: host)
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await run(alert, in: window)
    }

    // MARK: - confirm()

    func confirm(message: String, host: String, in window: NSWindow?) async -> Bool {
        // 抑制中は既定に倒す（＝取り消し扱い）。
        // 承諾を既定にすると、抑制を押しただけで
        // 「削除しますか？」に片端から はい と答えることになる
        guard !suppressed else { return false }
        let alert = base(message: message, host: host)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await run(alert, in: window) == .alertFirstButtonReturn
    }

    // MARK: - prompt()

    func prompt(message: String,
                defaultText: String,
                host: String,
                in window: NSWindow?) async -> String? {
        guard !suppressed else { return nil }
        let alert = base(message: message, host: host)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        alert.accessoryView = field
        // 打ち込む欄が焦点を持っていないと、開くなり Tab を押す羽目になる。
        // alert.window に触るとここで盤が組み上がる（accessoryView を
        // 差した後でなければ、初期の焦点は受け付けられない）
        alert.window.initialFirstResponder = field

        let response = await run(alert, in: window)
        // 取り消しは空文字ではなく null。ページ側はこれで
        // 「入力された空文字」と「取り消し」を見分けている
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - beforeunload（離脱確認）

    // 「このページを離れますか？」。WKUIDelegate には公開の窓口が無く、
    // 実装しない限り WebKit は無条件で離脱を許す（＝書きかけが黙って消える）。
    // 受け口は _WKUIDelegatePrivate 側にあるので、呼び元は Tab の @objc 宣言だ。
    //
    // ページが渡してくる文言は使わない。Safari も Chrome も同じで、
    // 「保存しないと消えます、今すぐ課金してください」の類を
    // ブラウザの盤に代弁させないための決まりだ。
    // 抑制ボタンも付けない——これは安全のための問いなので、黙らせない
    func confirmUnload(host: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = host.isEmpty
            ? String(localized: "Leave this page?")
            : String(localized: "Leave “\(host)”?")
        alert.informativeText = String(localized: "Changes you made may not be saved.")
        alert.addButton(withTitle: String(localized: "Leave Page"))
        alert.addButton(withTitle: String(localized: "Stay on Page"))
        // 誤って Return を叩いても離脱しないよう、既定は「留まる」に置く
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return await run(alert, in: window) == .alertFirstButtonReturn
    }

    // MARK: - 組み立てと上映

    private func base(message: String, host: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = host.isEmpty
            ? String(localized: "This page says:")
            : String(localized: "“\(host)” says:")
        alert.informativeText = Self.trimmed(message)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title =
            String(localized: "Don't show more dialogs on this page")
        return alert
    }

    private func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            // 窓に貼り付ける（シート）。他の窓の操作は止めない。
            // 既に別のシートが出ている場合は AppKit が順番待ちにしてくれる
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            // 貼る先が無い（窓が畳まれた等）。ここで諦めると
            // completionHandler が呼ばれずページが固まるので、アプリ全体で受ける
            response = alert.runModal()
        }
        if alert.suppressionButton?.state == .on { suppressed = true }
        return response
    }

    // ページの文言は長さも行数も好き放題に書ける。
    // そのまま渡すと盤が画面を突き抜けて、ボタンが押せなくなる
    private static let messageLimit = 1500

    private static func trimmed(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard flattened.count > messageLimit else { return flattened }
        return String(flattened.prefix(messageLimit)) + "…"
    }
}
