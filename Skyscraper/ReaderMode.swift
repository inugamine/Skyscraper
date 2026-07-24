//
//  ReaderMode.swift
//  Skyscraper
//
//  リーダーモード。
//  判定と本文抽出は Mozilla の Readability（Firefox のリーダービューと同じ
//  実装・Apache 2.0）に任せ、表示はアール・デコ調のオーバーレイで行う。
//  ページ自体は裏に残したまま被せるだけなので、戻るのは剥がすだけで済む。
//
//  Readability.js / Readability-readerable.js はバンドル同梱のリソースから
//  読む。無ければリーダーモードは静かに無効になる（ボタンが出ないだけ）。
//

import Foundation

enum Reader {

    // 本文抽出器（約90KB）。ボタンが押されたときだけページに注入する
    static let readabilityJS: String = load("Readability")
    // 「このページはリーダー表示に向くか」の判定器（小さいので毎ページ評価する）
    static let readerableJS: String = load("Readability-readerable")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("Reader: \(name).js not found in bundle — reader mode disabled")
            return ""
        }
        return source
    }

    // ── 判定 ──
    // ページ読み込み完了後に評価する。true ならアドレスバーにボタンを出す
    static var detectJS: String {
        guard !readerableJS.isEmpty else { return "false;" }
        return """
        (() => {
            try {
                \(readerableJS)
                return isProbablyReaderable(document);
            } catch (e) { return false; }
        })();
        """
    }

    // ── 入場 ──
    // Readability を注入し、document の複製から本文を抽出して
    // オーバーレイに流し込む（複製に対して走らせるのは、Readability が
    // 解析中に DOM を壊す造りのため。本家も同じ注意書きをしている）。
    // 成功なら true を返す
    static var enterJS: String {
        guard !readabilityJS.isEmpty else { return "false;" }
        return """
        (() => {
            if (document.getElementById('__skyscraper-reader')) { return true; }
            try {
                \(readabilityJS)
                const article = new Readability(document.cloneNode(true)).parse();
                if (!article || !article.content) { return false; }

                const style = document.createElement('style');
                style.id = '__skyscraper-reader-style';
                style.textContent = `\(css)`;

                const overlay = document.createElement('div');
                overlay.id = '__skyscraper-reader';
                const column = document.createElement('div');
                column.className = '__sr-column';

                const title = document.createElement('h1');
                title.className = '__sr-title';
                title.textContent = article.title || document.title;
                column.appendChild(title);

                const meta = [article.byline, article.siteName]
                    .filter(Boolean).join('  —  ');
                if (meta) {
                    const byline = document.createElement('div');
                    byline.className = '__sr-byline';
                    byline.textContent = meta;
                    column.appendChild(byline);
                }

                const rule = document.createElement('div');
                rule.className = '__sr-rule';
                column.appendChild(rule);

                const body = document.createElement('div');
                body.className = '__sr-body';
                body.innerHTML = article.content;
                column.appendChild(body);

                overlay.appendChild(column);
                (document.head || document.documentElement).appendChild(style);
                document.documentElement.appendChild(overlay);
                return true;
            } catch (e) { return false; }
        })();
        """
    }

    // ── 退場 ──
    static let exitJS = """
    (() => {
        document.getElementById('__skyscraper-reader')?.remove();
        document.getElementById('__skyscraper-reader-style')?.remove();
    })();
    """

    // ── 装い ──
    // ロビーと同じ闇と金。本文はセリフ体のクリーム、罫の中央にダイヤを一粒。
    // 注意: この CSS は JS のテンプレートリテラル（バッククォート）に
    // 流し込むので、バッククォートと ${ は使わないこと
    private static let css = """
    #__skyscraper-reader {
        position: fixed; inset: 0;
        background: #0d0d0d;
        z-index: 2147483647;
        overflow-y: auto;
        overscroll-behavior: contain;
    }
    .__sr-column {
        max-width: 680px;
        margin: 0 auto;
        padding: 64px 32px 96px;
        font-family: Georgia, 'Times New Roman', 'Hiragino Mincho ProN', 'Yu Mincho', serif;
        color: #e8d9b0;
        font-size: 17px;
        line-height: 1.9;
    }
    .__sr-title {
        font-size: 28px; line-height: 1.45;
        color: #e8d9b0; letter-spacing: 0.04em;
        margin: 0 0 12px; font-weight: 600;
    }
    .__sr-byline {
        font-size: 13px; color: #8a7a52;
        letter-spacing: 0.06em; margin-bottom: 28px;
    }
    .__sr-rule {
        height: 1px; background: #5a4c2a;
        margin: 0 0 44px; position: relative;
    }
    .__sr-rule::after {
        content: ''; position: absolute;
        left: 50%; top: -4px; width: 9px; height: 9px;
        transform: translateX(-50%) rotate(45deg);
        border: 1px solid #c9a34e; background: #0d0d0d;
    }
    .__sr-body h1, .__sr-body h2, .__sr-body h3, .__sr-body h4 {
        color: #e8d9b0; letter-spacing: 0.03em; line-height: 1.5;
        margin: 40px 0 16px;
    }
    .__sr-body p { margin: 0 0 1.2em; }
    .__sr-body a { color: #c9a34e; }
    .__sr-body img, .__sr-body video, .__sr-body figure {
        max-width: 100%; height: auto;
        margin: 28px auto; display: block;
    }
    .__sr-body figure img { margin: 0 auto; }
    .__sr-body figcaption {
        font-size: 13px; color: #8a7a52;
        text-align: center; margin-top: 10px;
    }
    .__sr-body blockquote {
        margin: 24px 0; padding: 4px 0 4px 20px;
        border-left: 2px solid #c9a34e; color: #cbbd97;
    }
    .__sr-body pre, .__sr-body code {
        font-family: ui-monospace, 'SF Mono', Menlo, monospace;
        font-size: 14px; background: #1a1712; color: #e8d9b0;
    }
    .__sr-body pre {
        padding: 16px; overflow-x: auto;
        border: 1px solid #5a4c2a; line-height: 1.6;
    }
    .__sr-body hr {
        border: none; height: 1px;
        background: #5a4c2a; margin: 40px 0;
    }
    .__sr-body table {
        border-collapse: collapse; margin: 24px 0; font-size: 15px;
    }
    .__sr-body th, .__sr-body td {
        border: 1px solid #5a4c2a; padding: 8px 12px;
    }
    """
}
