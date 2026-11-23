//
//  ReaderMode.swift
//  Skyscraper
//
//  リーダーモード。
//  判定と本文抽出は Mozilla の Readability (Firefox のリーダービューと同じ実装・Apache 2.0)に任せ、
//  表示はアール・デコ調のオーバーレイで行う。
//  ページ自体は裏に残したまま被せるだけなので、戻るのは剥がすだけで済む。
//
//  Readability の前後の手当て (掃除・日本語向けの判定・複数ページの結合・pixiv の小説) は
//  ReaderExtract.js にある。Mezzanine の抜き出しと同じ中身。
//
//  Readability.js / Readability-readerable.js / ReaderExtract.js はバンドル同梱のリソースから
//  読む。無ければリーダーモードは静かに無効になる (ボタンが出ないだけ)。
//

import Foundation

enum Reader {

    // 本文抽出器 (約90KB)。ボタンが押されたときだけページに注入する
    static let readabilityJS: String = load("Readability")
    // 「このページはリーダー表示に向くか」の判定器 (小さいので毎ページ評価する)
    static let readerableJS: String = load("Readability-readerable")
    // 前後の手当て。入口は readerCheck() と readerExtract()
    static let extractJS: String = load("ReaderExtract")

    // pixiv のシリーズの移動 (前の話・次の話) をリーダーから辿ったときに立てる旗 (sessionStorage の鍵)。
    // 行き先のページの判定で見つけたら、そのままリーダーで開く
    static let continueKey = "__skyscraper-reader-continue"

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("Reader: \(name).js not found in bundle — reader mode disabled")
            return ""
        }
        return source
    }

    /// ページを見分ける鍵。# 以降 (ページ内の位置) は捨てる。
    /// pixiv の小説は #2 のような印でページを送るので、それでリーダーを畳まないため
    static func pageKey(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.string
    }

    // ── 判定 ──
    // ページ読み込み完了後 (と、読み込み直さずに URL が変わった後) に評価する。
    // { available, resume, active } を返す。
    //   available … アドレスバーにボタンを出すか
    //   resume    … シリーズの移動を辿ってきたので、そのままリーダーで開くか
    //   active    … 紙面が既に被さっているか (戻る・進むでキャッシュから戻ったページ)
    static var detectJS: String {
        guard !readerableJS.isEmpty, !extractJS.isEmpty else {
            return "({ available: false, resume: false, active: false });"
        }
        return """
        (() => {
            try {
                \(readerableJS)
                \(extractJS)
                let resume = false;
                try {
                    resume = sessionStorage.getItem('\(continueKey)') === '1';
                    sessionStorage.removeItem('\(continueKey)');
                } catch (e) {}
                const available = readerCheck();
                const active = !!document.getElementById('__skyscraper-reader');
                return { available: available, resume: resume && available, active: active };
            } catch (e) { return { available: false, resume: false, active: false }; }
        })();
        """
    }

    // ── 入場 ──
    // callAsyncJavaScript で呼ぶ関数の本体 (pixiv の本文や続きのページを取りに行くので、待てる形にしてある)。
    // Readability を注入して本文を抽出し、オーバーレイに流し込む。成功なら true を返す。
    // 汎用の抜き出しは document の複製に対して走らせる (Readability が解析中に DOM を壊す造りのため。本家も同じ注意書きをしている)
    static var enterBody: String {
        guard !readabilityJS.isEmpty, !readerableJS.isEmpty, !extractJS.isEmpty else { return "return false;" }
        return """
        if (document.getElementById('__skyscraper-reader')) { return true; }
        const pageKey = () => location.href.split('#')[0];
        const startedAt = pageKey();
        try {
            \(readerableJS)
            \(readabilityJS)
            \(extractJS)
            const article = await readerExtract();
            if (!article || article.error || !article.content) { return false; }
            // 取りに行っている間に別のページへ移っていたら (画面を JS で描き替えるサイト)、被せない
            if (pageKey() !== startedAt) { return false; }
            if (document.getElementById('__skyscraper-reader')) { return true; }

            const vertical = !!article.vertical;

            const style = document.createElement('style');
            style.id = '__skyscraper-reader-style';
            style.textContent = `\(css)`;

            const overlay = document.createElement('div');
            overlay.id = '__skyscraper-reader';
            overlay.tabIndex = -1;
            if (article.lang) { overlay.lang = article.lang; }
            if (vertical) { overlay.classList.add('__sr-vertical'); }
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

            // シリーズの移動 (pixiv の前の話・次の話) を普通にクリックしたら、行き先でもリーダーで開く。
            // ⌘クリックなどで別のタブへ開くときは旗を立てない (このタブの次のページで勝手に開いてしまうため)
            body.querySelectorAll('.__sr-series a[href]').forEach((a) => {
                a.addEventListener('click', (e) => {
                    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) { return; }
                    try { sessionStorage.setItem('\(continueKey)', '1'); } catch (err) {}
                });
            });

            // ── キーで読み進める ──
            // 紙面はページの上に被せた箱なので、何もしないと矢印や空白キーは裏のページに届き、
            // 裏のページが動いたり、サイトの操作 (pixiv のページ送りなど) が走ったりする。
            // 窓で先に受けて紙面を動かし、裏へは流さない。
            // 縦書きは左へ読み進めるので、下へ進むキーは左へ動かす
            const onKey = (e) => {
                if (e.metaKey || e.ctrlKey || e.altKey) { return; }
                const t = e.target;
                if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || ''))) { return; }
                const line = 60;
                const page = (vertical ? overlay.clientWidth : overlay.clientHeight) * 0.85;
                let d = null; // 読み進める向きに何ピクセル動かすか
                switch (e.key) {
                    case 'ArrowDown': d = line; break;
                    case 'ArrowUp': d = -line; break;
                    case 'ArrowLeft': d = vertical ? line : 0; break;
                    case 'ArrowRight': d = vertical ? -line : 0; break;
                    case 'PageDown': d = page; break;
                    case 'PageUp': d = -page; break;
                    case ' ': d = e.shiftKey ? -page : page; break;
                    case 'Home': d = -Infinity; break;
                    case 'End': d = Infinity; break;
                }
                if (d === null) { return; }
                e.preventDefault();
                e.stopImmediatePropagation();
                if (d === 0) { return; }
                const far = vertical ? overlay.scrollWidth : overlay.scrollHeight;
                if (!isFinite(d)) { d = Math.sign(d) * far; }
                const behavior = Math.abs(d) > line ? 'smooth' : 'auto';
                if (vertical) {
                    overlay.scrollBy({ left: -d, behavior: behavior });
                } else {
                    overlay.scrollBy({ top: d, behavior: behavior });
                }
            };
            window.addEventListener('keydown', onKey, true);

            // 縦書きでは、マウスのホイール (縦の回転) を横の送りに替える。
            // 下へ回すと読み進める (左へ動く)。ピンチ (ctrlKey 付きで届く) には手を出さない
            if (vertical) {
                overlay.addEventListener('wheel', (e) => {
                    if (e.ctrlKey || Math.abs(e.deltaY) <= Math.abs(e.deltaX)) { return; }
                    e.preventDefault();
                    const unit = e.deltaMode === 1 ? 16 : (e.deltaMode === 2 ? overlay.clientWidth : 1);
                    overlay.scrollLeft -= e.deltaY * unit;
                }, { passive: false });
            }

            window.__skyscraperReaderCleanup = () => {
                window.removeEventListener('keydown', onKey, true);
            };

            overlay.appendChild(column);
            (document.head || document.documentElement).appendChild(style);
            document.documentElement.appendChild(overlay);
            overlay.focus({ preventScroll: true });
            return true;
        } catch (e) { return false; }
        """
    }

    // ── 退場 ──
    static let exitJS = """
    (() => {
        window.__skyscraperReaderCleanup?.();
        delete window.__skyscraperReaderCleanup;
        document.getElementById('__skyscraper-reader')?.remove();
        document.getElementById('__skyscraper-reader-style')?.remove();
    })();
    """

    // ── 装い ──
    // ロビーと同じ地と金。本文はセリフ体のクリーム、罫の中央にダイヤを一粒。
    // 色は入場の度に今の配色 (Theme.swift) から引く。
    // 余白や罫は margin-block / inline-size のような「書く向きに沿った」言い方で書いてあるので、
    // 縦書き (.__sr-vertical) でもほとんどそのまま縦に回る。縦書きだけの違いは末尾にまとめた。
    // 注意: この CSS は JS のテンプレートリテラル (バッククォート) に流し込むので、バッククォートと ${ は使わないこと
    private static var css: String {
        let p = DecoThemeStore.shared.theme.palette
        let ink = DecoPalette.css(p.ink)
        let panel2 = DecoPalette.css(p.panel2)
        let gold = DecoPalette.css(p.gold)
        let cream = DecoPalette.css(p.cream)
        let dim = DecoPalette.css(p.dimGold)
        let faint = DecoPalette.css(p.faintGold)
        return """
        #__skyscraper-reader {
            position: fixed; inset: 0;
            background: \(ink);
            z-index: 2147483647;
            overflow-y: auto;
            overscroll-behavior: contain;
        }
        #__skyscraper-reader:focus { outline: none; }
        .__sr-column {
            max-inline-size: 680px;
            margin-inline: auto;
            padding-block: 64px 96px;
            padding-inline: 32px;
            font-family: Georgia, 'Times New Roman', 'Hiragino Mincho ProN', 'Yu Mincho', serif;
            color: \(cream);
            font-size: 17px;
            line-height: 1.9;
        }
        .__sr-title {
            font-size: 28px; line-height: 1.45;
            color: \(cream); letter-spacing: 0.04em;
            margin-block: 0 12px; margin-inline: 0; font-weight: 600;
        }
        .__sr-byline {
            font-size: 13px; color: \(dim);
            letter-spacing: 0.06em; margin-block-end: 28px;
        }
        .__sr-rule {
            block-size: 1px; background: \(faint);
            margin-block: 0 44px; position: relative;
        }
        .__sr-rule::after {
            content: ''; position: absolute;
            inset-inline-start: 50%; inset-block-start: -4px;
            inline-size: 9px; block-size: 9px;
            margin-inline-start: -5.5px;
            transform: rotate(45deg);
            border: 1px solid \(gold); background: \(ink);
        }
        .__sr-body h1, .__sr-body h2, .__sr-body h3, .__sr-body h4 {
            color: \(cream); letter-spacing: 0.03em; line-height: 1.5;
            margin-block: 40px 16px; margin-inline: 0;
        }
        .__sr-body p { margin-block: 0 1.2em; margin-inline: 0; }
        .__sr-body a { color: \(gold); }
        .__sr-body img, .__sr-body video, .__sr-body figure {
            max-inline-size: 100%; block-size: auto;
            margin-block: 28px; margin-inline: auto; display: block;
        }
        .__sr-body figure img { margin: 0 auto; }
        .__sr-body figcaption {
            font-size: 13px; color: \(dim);
            text-align: center; margin-block-start: 10px;
        }
        .__sr-body blockquote {
            margin-block: 24px; margin-inline: 0;
            padding-block: 4px; padding-inline: 20px 0;
            border-inline-start: 2px solid \(gold); color: color-mix(in srgb, \(cream) 85%, \(ink));
        }
        .__sr-body pre, .__sr-body code {
            font-family: ui-monospace, 'SF Mono', Menlo, monospace;
            font-size: 14px; background: \(panel2); color: \(cream);
        }
        .__sr-body pre {
            padding: 16px; overflow-x: auto;
            border: 1px solid \(faint); line-height: 1.6;
        }
        .__sr-body hr {
            border: none; block-size: 1px;
            background: \(faint); margin-block: 40px;
        }
        .__sr-body table {
            border-collapse: collapse; margin-block: 24px; font-size: 15px;
        }
        .__sr-body th, .__sr-body td {
            border: 1px solid \(faint); padding: 8px 12px;
        }

        /* ---- 続きのページ・pixiv の [newpage] の区切り (ページ番号を罫で挟む) ---- */
        .__sr-pagebreak {
            display: flex; align-items: center; gap: 0.8em;
            margin-block: 3em;
            font-size: 0.8em; letter-spacing: 0.2em;
            color: \(gold);
        }
        .__sr-pagebreak::before, .__sr-pagebreak::after {
            content: ''; flex: 1;
            block-size: 1px; background: \(faint);
        }

        /* ---- pixiv の小説 ---- */
        /* 本文は改行と行頭の字下げをそのまま活かす */
        .__sr-novel-page { white-space: pre-wrap; }
        .__sr-body rt { font-size: 0.5em; }
        /* 傍点 ([[emphasismark:]])。斜体にはせず、字の脇にゴマを打つ */
        .__sr-emphasis {
            font-style: normal;
            -webkit-text-emphasis: filled sesame;
            text-emphasis: filled sesame;
        }
        /* 挿絵 ([pixivimage:] / [uploadedimage:]) */
        .__sr-illust { margin-block: 2em; white-space: normal; }

        /* ---- シリーズの移動 (前の話・次の話) ---- */
        .__sr-series {
            margin-block-start: 4em;
            padding-block-start: 2em;
            border-block-start: 1px solid \(faint);
            text-align: center;
        }
        .__sr-series-title {
            margin-block: 0 1.5em; margin-inline: 0;
            font-size: 0.8em; letter-spacing: 0.2em;
            color: \(gold);
        }
        .__sr-series-links {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 1em;
        }
        /* 横長の六角形の箱。外側 (a) を罫の色で六角形に切り抜き、
           内側 (.__sr-face) を 1px 小さく地の色で切り抜いて重ねると、六角形の縁だけが残る */
        .__sr-body .__sr-series-links a {
            --sr-cut: 0.9em;
            display: block;
            padding: 1px;
            background: \(faint);
            color: \(cream);
            text-decoration: none;
            clip-path: polygon(var(--sr-cut) 0, calc(100% - var(--sr-cut)) 0, 100% 50%,
                               calc(100% - var(--sr-cut)) 100%, var(--sr-cut) 100%, 0 50%);
        }
        .__sr-series-links .__sr-face {
            display: block;
            box-sizing: border-box;
            block-size: 100%;
            padding-block: 0.8em;
            padding-inline: calc(var(--sr-cut) + 0.6em);
            background: \(ink);
            line-height: 1.5;
            clip-path: polygon(var(--sr-cut) 0, calc(100% - var(--sr-cut)) 0, 100% 50%,
                               calc(100% - var(--sr-cut)) 100%, var(--sr-cut) 100%, 0 50%);
            transition: background 0.2s ease;
        }
        .__sr-body .__sr-series-links a:hover { background: \(gold); }
        .__sr-series-links a:hover .__sr-face { background: \(panel2); }
        .__sr-series-links .__sr-prev { text-align: start; }
        .__sr-series-links .__sr-next { text-align: end; }
        .__sr-series-links small {
            display: block;
            font-size: 0.7em; letter-spacing: 0.1em;
            color: \(gold);
        }

        /* ---- 縦書き ----
           pixiv で作者が縦書きを勧めている小説は、紙面ごと縦に組む。右から左へ読み進める */
        #__skyscraper-reader.__sr-vertical {
            writing-mode: vertical-rl;
            overflow-y: hidden;
            overflow-x: auto;
        }
        .__sr-vertical .__sr-column {
            box-sizing: border-box;
            padding-inline: 48px;
            overflow-wrap: anywhere;
        }
        /* 挿絵は回さずに立てたまま。行の長さ (高さ) と画面の幅の両方に収める */
        .__sr-vertical .__sr-body img, .__sr-vertical .__sr-body video {
            max-inline-size: 100%;
            max-block-size: 80vw;
            inline-size: auto;
            block-size: auto;
        }
        /* シリーズの箱は縦長の六角形に。尖りを上下に */
        .__sr-vertical .__sr-body .__sr-series-links a,
        .__sr-vertical .__sr-series-links .__sr-face {
            clip-path: polygon(0 var(--sr-cut), 50% 0, 100% var(--sr-cut),
                               100% calc(100% - var(--sr-cut)), 50% 100%, 0 calc(100% - var(--sr-cut)));
        }
        """
    }
}
