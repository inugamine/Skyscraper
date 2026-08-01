//
//  IMEGuard.swift
//  Skyscraper
//
//  日本語入力の「確定」Enter がページに素通りする問題の門番。
//
//  かな漢字変換を Enter で確定した時、WKWebView は確定処理を先に済ませてから
//  keydown を投げてくる。そのため keydown が来た時点で composition は既に
//  終わっており、event.isComposing は false、keyCode は 229 ではなく 13 になる。
//  ページ側から見ると「素の Enter が押された」としか判別できない。
//  Claude や Slack のように Enter で送信する作りのページでは、
//  変換を確定した瞬間に書きかけの文が飛んでいく。
//
//  ページ側は正しく isComposing を見ているのに、そこに乗る値が嘘なので
//  ページには直しようがない。ブラウザ側で塞ぐしかない。
//
//  やること：composition の開始と終了を自前で見張り、
//  「composition 中」または「終わった直後（猶予 60ms 以内）」の Enter を
//  ページの listener に届く前に握り潰す。
//  捕まえるのは Enter だけで、他のキーには一切触らない。
//
//  猶予を 60ms にしてあるのは、確定 → keydown が同じ入力の流れの中で
//  連続して起きるからだ。人間が確定した後に改めて Enter を叩くまでには
//  どう急いでも 100ms 以上かかるので、本物の送信 Enter は通り抜ける。
//

import Foundation
import WebKit

enum IMEGuard {
    // 全フレームに、他のスクリプトより先に仕込む。
    // 埋め込みの入力欄（iframe 内のコメント欄など）も対象にしたいので
    // forMainFrameOnly は false
    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let source = """
    (() => {
        if (window.__skyscraperIMEGuardInstalled) { return; }
        window.__skyscraperIMEGuardInstalled = true;

        // 確定直後とみなす猶予（ミリ秒）
        const graceMs = 60;

        let composing = false;
        let endedAt = -Infinity;

        // composition の見張り。capture 段で拾うので、
        // ページ側が stopPropagation していても取り逃がさない
        document.addEventListener('compositionstart', () => {
            composing = true;
        }, true);

        document.addEventListener('compositionupdate', () => {
            composing = true;
        }, true);

        document.addEventListener('compositionend', () => {
            composing = false;
            endedAt = performance.now();
        }, true);

        const isConfirmingEnter = (event) => {
            if (event.key !== 'Enter') { return false; }
            // 素直に composition 中だと名乗っている場合（他の入力方式や将来の修正）
            if (event.isComposing || event.keyCode === 229) { return true; }
            // 嘘をつかれている場合。確定の直後かどうかで見分ける
            if (composing) { return true; }
            return performance.now() - endedAt < graceMs;
        };

        const swallow = (event) => {
            if (!isConfirmingEnter(event)) { return; }
            // stopImmediatePropagation だけだと既定動作（改行の挿入）が残り、
            // 送信の代わりに空行が入る。preventDefault も併せて要る。
            // 確定処理はこの時点で既に終わっているので、
            // ここで既定を止めても変換が壊れることはない
            event.stopImmediatePropagation();
            event.preventDefault();
        };

        // keypress は廃止予定だが、古い作りのページがまだ見ている。
        // keyup を送信の合図にしているページもあるので三つとも塞ぐ
        ['keydown', 'keypress', 'keyup'].forEach((name) => {
            window.addEventListener(name, swallow, true);
        });
    })();
    """
}
