//
//  ReaderExtract.js
//  Skyscraper
//
//  リーダーモードの本文の抜き出し。Mezzanine の Preprocess.js から、Readability 本体を除いた部分を持ってきた物。
//    ・抜き出す前の掃除 (「人気の記事」「おすすめ」などの箱を取り除く)
//    ・読めそうかの判定 (日本語・中国語・韓国語は物差しを緩める)
//    ・複数ページに分かれた記事を、続きのページを裏で取ってきて一枚につなぐ
//    ・pixiv の小説は専用に抜き出す ([newpage] で分かれたページを全部つなぎ、ルビ・挿絵・シリーズの移動も組む)
//
//  これ単体では動かない。ReaderMode.swift が Readability-readerable.js と Readability.js の後ろに
//  この中身をつなげて、一つの関数の本体としてページに流し込む (isProbablyReaderable と Readability を使うため)。
//  入口は readerCheck() (判定だけ) と readerExtract() (抜き出し。Promise を返す) の二つ。
//
//  Mezzanine 側を直したら、こちらにも同じ直しを入れること。
//

// ==== 汎用の抜き出し（Readability） ====

// ==== 抜き出す前の掃除 ====
//
// Readability は「comment」「sidebar」「related」などの名前の箱を本文の候補から外すが、
// 「人気の記事」「おすすめ」「ニュースレター」のような箱は名前が載っていないので残ってしまう。
// しかも中身を後から JS で入れる作りだと、見出しと空の箇条書きだけが紙面に残る
// (Vogue の「Most Popular」= RecircMostPopularWrapper)。
// 抜き出す前に、名前 (class / id) でそれと分かる箱を取り除く。
// CSS-in-JS のサイトは「RecircMostPopularWrapper-kZskQo」のような名前なので、語の一部でも当てる。
var CLUTTER_NAMES = /recirc|most-?popular|popular-?(posts|articles|list|ranking)|ranking|recommend|you-?may-?also|also-?like|outbrain|taboola|newsletter|read-?more-?list|trending/i;

function removeClutter(doc) {
    var body = doc.body;
    if (!body) { return; }
    // ページの文字数 (<script> の中の JSON などは数えない。Vogue は本文 6 千字に対して script が 30 万字あった)
    var total = (body.textContent || "").length;
    [].forEach.call(body.querySelectorAll("script, style, noscript, template"), function (el) {
        total -= (el.textContent || "").length;
    });
    total = Math.max(total, 1);
    var found = [].slice.call(body.querySelectorAll("[class], [id]")).filter(function (el) {
        var name = (typeof el.className === "string" ? el.className : "") + " " + (el.id || "");
        return CLUTTER_NAMES.test(name);
    });
    found.forEach(function (el) {
        if (!el.isConnected) { return; }
        // 本文を抱えていそうな箱は残す (名前の当て方が外れて、記事ごと消してしまわないように)。
        // 記事の見出しや <article> を含む、長い段落が三つ以上ある、ページの文字の四割を超える、のどれか
        if (el.querySelector("article, h1")) { return; }
        var longParagraphs = [].filter.call(el.querySelectorAll("p"), function (p) {
            return (p.textContent || "").trim().length >= 60;
        }).length;
        if (longParagraphs >= 3) { return; }
        if ((el.textContent || "").length > total * 0.4) { return; }
        el.parentNode.removeChild(el);
    });

    // 中身の入っていない箇条書き (後から JS で埋める一覧の抜け殻) も消す
    [].slice.call(body.querySelectorAll("ul, ol")).forEach(function (list) {
        if (!list.isConnected) { return; }
        var empty = !(list.textContent || "").trim() && !list.querySelector("img, picture, video, svg");
        if (empty) { list.parentNode.removeChild(list); }
    });
}

// 記事として読めそうか。Readability の判定は「140 字以上の段落」を数える英語向けの物差しで、
// 一字に中身の詰まった日本語では足りない (ITmedia は段落を短く切るので、1 段落しか数えられず「読めない」になった)。
// 日本語・中国語・韓国語のページは 60 字以上の段落を数える。一覧のページ (ITmedia・Yahoo!ニュースのトップや
// カテゴリ) は 60 字にしても目安 (20) に届かないことを確かめた
function looksReadable(doc) {
    if (isProbablyReaderable(doc)) { return true; }
    var lang = (doc.documentElement.getAttribute("lang") || "").toLowerCase();
    var cjk = /^(ja|zh|ko)/.test(lang) || /[\u3040-\u30ff\u4e00-\u9fff\uac00-\ud7af]/.test(doc.title || "");
    return cjk && isProbablyReaderable(doc, { minContentLength: 60 });
}

function extractGeneric() {
    // 記事っぽくないページは、抽出する前に除外する
    if (!looksReadable(document)) {
        return { url: document.URL, title: document.title, error: "記事ではなさそうです" };
    }
    
    var article = null;
    try {
        // ページ本体ではなく、複製した DOM に対して実行する
        var copy = document.cloneNode(true);
        removeClutter(copy);
        article = new Readability(copy, { linkDensityModifier: 0.1 }).parse();
    } catch (e) {
        return { url: document.URL, title: document.title, error: String(e) };
    }
    
    if (!article) {
        return { url: document.URL, title: document.title, error: "本文が見つかりませんでした" };
    }
    
    return {
        url: document.URL,
        title: article.title || document.title,
        byline: article.byline || "",
        siteName: article.siteName || "",
        lang: article.lang || "",
        excerpt: article.excerpt || "",
        length: article.length || 0,
        content: article.content || ""
    };
}

// ==== 複数ページの記事をつなげる ====
//
// 「1 2 3 次へ」のように URL ごとに分かれた記事を、次のページを裏で取りに行って一枚につなげる。
// 「次のページ」かどうかは、リンクの文字ではなく URL の形で決める (文字で決めると「次の記事」まで拾うため)。
//   ・クエリ      … ?page=2 / ?p=2 など
//   ・パスの末尾  … /記事/2/  /page/2/  /記事_2.html  /記事-2.html
// 今のページの URL を「1ページ目」(または N ページ目) と読み、同じ形でページ番号だけが 1 進んだリンクを探す。
// 念のため、取ってきたページの題 (<title>) が今のページと似ていなければ別の記事とみなして止める。

var JOIN_MAX_PAGES = 20;     // つなげるのは最大でこのページ数まで
var JOIN_TIME_BUDGET = 15000; // 続きのページを取りに行くのは、合わせてこの時間まで (ミリ秒)
// ページ番号とみなす数の上限。/archives/123 → /archives/124 のような「記事の番号が一つ違い」を
// ページ送りと取り違えないよう、大きな数はページ番号とみなさない
var JOIN_PAGE_LIMIT = 50;
var PAGE_PARAMS = ["page", "p", "pg", "pn", "pageno", "paged", "pnum"];

// URL を「どの形で何ページ目か」の読み方の一覧にする。{ key, params, page, self }
//   key    … 形の名前と、ページ番号を除いた場所 (同じ key なら同じ記事のページの候補)
//   params … ページ番号以外のクエリ (並べ替え済みの「名前=値」の一覧)
//   self   … true なら「この URL そのものを 1 ページ目とみなす」読み方
function pageReadings(href, baseURI) {
    var url;
    try { url = new URL(href, baseURI); } catch (e) { return []; }
    if (!/^https?:$/.test(url.protocol)) { return []; }
    url.hash = "";
    var readings = [];
    var origin = url.origin;
    var path = url.pathname.replace(/\/+$/, "") || "/";

    function queryPairs(params) {
        var pairs = [];
        params.forEach(function (value, name) { pairs.push(name + "=" + value); });
        return pairs.sort();
    }

    // クエリのページ番号
    PAGE_PARAMS.forEach(function (name) {
        var params = new URLSearchParams(url.search);
        var value = params.get(name);
        params.delete(name);
        var key = "q:" + name + ":" + origin + path;
        if (value === null) {
            readings.push({ key: key, params: queryPairs(params), page: 1, self: true });
        } else if (/^\d{1,2}$/.test(value) && parseInt(value, 10) <= JOIN_PAGE_LIMIT) {
            readings.push({ key: key, params: queryPairs(params), page: parseInt(value, 10), self: false });
        }
    });

    // パスの末尾のページ番号
    var all = queryPairs(new URLSearchParams(url.search));
    var patterns = [
        { name: "page", re: /^(.*)\/page\/(\d{1,3})$/, base: function (m) { return m[1]; } },
        { name: "dir",  re: /^(.*)\/(\d{1,3})$/,       base: function (m) { return m[1]; } },
        { name: "file", re: /^(.*)[_-](\d{1,3})(\.[a-z]+)$/i, base: function (m) { return m[1] + m[3]; } }
    ];
    patterns.forEach(function (pattern) {
        readings.push({ key: "p:" + pattern.name + ":" + origin + path, params: all, page: 1, self: true });
        var m = path.match(pattern.re);
        if (m && parseInt(m[2], 10) <= JOIN_PAGE_LIMIT) {
            readings.push({ key: "p:" + pattern.name + ":" + origin + pattern.base(m), params: all,
                            page: parseInt(m[2], 10), self: false });
        }
    });
    return readings;
}

// 二つの読み方が同じ記事を指しているか。場所が同じで、残りのクエリの片方がもう片方に含まれていればよい
// (東洋経済の「?display=b」のように、1 ページ目にだけ付く飾りのクエリがあるため)
function sameArticle(a, b) {
    if (a.key !== b.key) { return false; }
    function within(small, large) {
        return small.every(function (pair) { return large.indexOf(pair) >= 0; });
    }
    return within(a.params, b.params) || within(b.params, a.params);
}

// URL から # 以降を落とした形
function withoutHash(href, baseURI) {
    try { var url = new URL(href, baseURI); url.hash = ""; return url.href; } catch (e) { return null; }
}

// doc (URL は pageURL) の中から「次のページ」へのリンクを探す。
// 見つかれば { url, reading, page } を、無ければ null を返す。
// known (前に見つけた次のページの読み方の一覧) を渡すと、それと同じ記事を指す読み方だけに絞る
function findNextPage(doc, pageURL, known) {
    var current = pageReadings(pageURL, pageURL).filter(function (r) {
        return !known || known.some(function (k) { return sameArticle(k, r); });
    });
    if (current.length === 0) { return null; }
    var here = withoutHash(pageURL, pageURL);
    var links = [].slice.call(doc.querySelectorAll("a[href], link[rel~='next'][href]"));
    for (var i = 0; i < links.length; i++) {
        var href = withoutHash(links[i].getAttribute("href"), doc.baseURI || pageURL);
        if (!href || href === here) { continue; }
        var readings = pageReadings(href, pageURL);
        for (var j = 0; j < readings.length; j++) {
            var r = readings[j];
            if (r.self || r.page < 2) { continue; }
            for (var k = 0; k < current.length; k++) {
                if (current[k].page + 1 === r.page && sameArticle(current[k], r)) {
                    return { url: href, reading: r, page: r.page };
                }
            }
        }
    }
    return null;
}

// 二つの題が同じ記事のものに見えるか。「題 (2/3) - サイト名」のような違いは許す
function similarTitles(a, b) {
    a = (a || "").replace(/\s+/g, "");
    b = (b || "").replace(/\s+/g, "");
    if (!a || !b) { return true; }
    if (a === b || a.indexOf(b) >= 0 || b.indexOf(a) >= 0) { return true; }
    var n = 0;
    while (n < a.length && n < b.length && a[n] === b[n]) { n++; }
    return n >= Math.min(a.length, b.length) * 0.5;
}

// 取ってきたバイト列を文字にする。文字コードは応答の見出し、無ければ <meta charset> から
function decodeHTML(buffer, contentType) {
    var charset = (/charset=["']?([\w-]+)/i.exec(contentType || "") || [])[1];
    if (!charset) {
        var head = new TextDecoder("latin1").decode(buffer.slice(0, 4096));
        charset = (/<meta[^>]+charset=["']?([\w-]+)/i.exec(head) || [])[1];
    }
    try {
        return new TextDecoder(charset || "utf-8").decode(buffer);
    } catch (e) {
        return new TextDecoder("utf-8").decode(buffer);
    }
}

// 続きのページを取ってきて、DOM にする (相対リンクが元のページ基準で解けるよう <base> を入れる)
function fetchDocument(url) {
    return fetch(url, { credentials: "same-origin" })
    .then(function (response) {
        if (!response.ok) { throw new Error("HTTP " + response.status); }
        var type = response.headers.get("content-type") || "";
        return response.arrayBuffer().then(function (buffer) { return decodeHTML(buffer, type); });
    })
    .then(function (html) {
        var doc = new DOMParser().parseFromString(html, "text/html");
        if (!doc.querySelector("base[href]")) {
            var base = doc.createElement("base");
            base.setAttribute("href", url);
            (doc.head || doc.documentElement).insertBefore(base, (doc.head || doc.documentElement).firstChild);
        }
        return doc;
    });
}

// 本文の HTML から、ページ送り (「1 2 3 次へ」「続きを読む」など) を取り除く。
// 同じ記事のページ (known と同じ記事を指す URL) へのリンクを消し、まわりにページ送りの文字しか残らない箱ごと消す
function removePagination(html, known, pageURL) {
    var doc = document.implementation.createHTMLDocument("");
    var base = doc.createElement("base");
    base.setAttribute("href", pageURL);
    doc.head.appendChild(base);
    var root = doc.createElement("div");
    root.innerHTML = html;
    doc.body.appendChild(root);

    var anchors = [].slice.call(root.querySelectorAll("a[href]")).filter(function (a) {
        return pageReadings(a.getAttribute("href"), pageURL).some(function (r) {
            return known.some(function (k) { return sameArticle(k, r); });
        });
    });
    if (anchors.length === 0) { return html; }
    anchors.forEach(function (a) { a.setAttribute("data-skyscraper-pager", ""); });

    // 箱の中から、ページ送りのリンクの文字とページ送りらしい言葉を除いて、何も残らないか
    function onlyPagination(el) {
        var text = "";
        var walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
            if (!walker.currentNode.parentNode.closest("[data-skyscraper-pager]")) {
                text += walker.currentNode.nodeValue;
            }
        }
        text = text.replace(/次の?ページ|前の?ページ|次へ|前へ|続きを読む|続き|ページ|頁|最初|最後|next|prev(ious)?|page|first|last/gi, "");
        return !/[^\s\d\/|｜・…<>＜＞«»‹›←→〈〉《》()（）\[\]［］.,、。:：\-ー〜~]/.test(text);
    }

    anchors.forEach(function (a) {
        if (!a.isConnected) { return; }
        // 「?page=2#見出し」のような目次のリンクは、つなげた後は同じ紙面の中の見出しを指す。
        // 文字は残して、リンクだけ外す
        if (/#./.test(a.getAttribute("href"))) {
            while (a.firstChild) { a.parentNode.insertBefore(a.firstChild, a); }
            a.parentNode.removeChild(a);
            return;
        }
        var node = a;
        while (node.parentNode && node.parentNode !== root && onlyPagination(node.parentNode)) {
            node = node.parentNode;
        }
        node.parentNode.removeChild(node);
    });
    return root.innerHTML;
}

// first (汎用の抜き出しの結果) に、続きのページをつなげてから completion に渡す
function joinPages(first, completion) {
    var next = findNextPage(document, document.URL, null);
    if (!next) { completion(first); return; }

    var started = Date.now();
    var known = [next.reading];
    var firstTitle = document.title;
    var visited = [withoutHash(document.URL, document.URL)];
    var texts = [];
    var parts = [{ page: next.page - 1, url: document.URL, content: first.content }];
    var length = first.length || 0;

    function finish() {
        if (parts.length < 2) { completion(first); return; }
        var html = parts.map(function (part, i) {
            var body = removePagination(part.content, known, part.url);
            var divider = i === 0 ? "" : '<div class="__sr-pagebreak" aria-hidden="true">' + part.page + "</div>";
            return divider + body;
        }).join("");
        var result = {};
        Object.keys(first).forEach(function (name) { result[name] = first[name]; });
        result.content = html;
        result.length = length;
        completion(result);
    }

    function step(target) {
        if (!target || parts.length >= JOIN_MAX_PAGES || Date.now() - started > JOIN_TIME_BUDGET ||
            visited.indexOf(target.url) >= 0) {
            finish();
            return;
        }
        visited.push(target.url);
        fetchDocument(target.url).then(function (doc) {
            if (!similarTitles(firstTitle, doc.title)) { finish(); return; }
            // 次のページは Readability より先に探す (Readability は渡した DOM を組み替え、ページ送りを捨ててしまう)
            var following = findNextPage(doc, target.url, known);
            removeClutter(doc);
            var article = new Readability(doc, { linkDensityModifier: 0.1 }).parse();
            var text = article && (article.textContent || "").replace(/\s+/g, "");
            // 中身が無い・前のページと同じ (存在しないページ番号で 1 ページ目が返ってくるサイトなど) なら止める
            if (!text || text.length < 100 || texts.indexOf(text) >= 0) { finish(); return; }
            texts.push(text);
            parts.push({ page: target.page, url: target.url, content: article.content || "" });
            length += article.length || 0;
            if (following) { known.push(following.reading); }
            step(following);
        }).catch(function () {
            finish();
        });
    }
    step(next);
}

// 汎用の抜き出しに、続きのページをつなげて completion に渡す。つなげる途中で何か起きても、1ページ目だけは必ず渡す
function extractGenericJoined(completion) {
    var first = extractGeneric();
    if (first.error) { completion(first); return; }
    try {
        joinPages(first, completion);
    } catch (e) {
        completion(first);
    }
}

// ==== pixiv 小説専用の抜き出し ====

// pixiv の小説ページなら作品 ID を、違うなら null を返す
function pixivNovelId() {
    if (!/(^|\.)pixiv\.net$/.test(location.hostname)) return null;
    if (location.pathname !== "/novel/show.php") return null;
    return new URLSearchParams(location.search).get("id");
}

function escapeHTML(text) {
    return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// 挿絵を1枚の図にする。画像の場所が分からない挿絵は消す
function illustHTML(url) {
    if (!url) return "";
    return '<figure class="__sr-illust"><img src="' + escapeHTML(url) + '" alt="" loading="lazy"></figure>';
}

// pixiv 独自の記法で書かれた1ページ分の本文を、HTML にする。
// images は挿絵の場所の表 { uploaded: { 画像ID: URL }, pixiv: { "作品ID" か "作品ID-ページ": URL } }
function pixivPageToHTML(text, images) {
    return escapeHTML(text)
    // [[rb:漢字 > かんじ]] → ルビ（エスケープ後なので、> は &gt; になっている）
    .replace(/\[\[rb:\s*(.+?)\s*&gt;\s*(.+?)\s*\]\]/g, "<ruby>$1<rt>$2</rt></ruby>")
    // [[emphasismark:文字 > 印]] → 傍点（印の種類は気にせず、ゴマの点で打つ）
    .replace(/\[\[emphasismark:\s*(.+?)\s*&gt;\s*(.+?)\s*\]\]/g, '<em class="__sr-emphasis">$1</em>')
    // [b:太字] [i:斜体]
    .replace(/\[b:(.+?)\]/g, "<b>$1</b>")
    .replace(/\[i:(.+?)\]/g, "<i>$1</i>")
    // [chapter:見出し] → 見出し
    .replace(/\[chapter:\s*(.+?)\s*\]/g, "<h2>$1</h2>")
    // [[jumpuri:文字 > URL]] → リンク（http と https だけ）
    .replace(/\[\[jumpuri:\s*(.+?)\s*&gt;\s*(https?:\/\/[^\s\]]+)\s*\]\]/g, '<a href="$2">$1</a>')
    // 挿絵。[uploadedimage:画像ID] は小説に上げた画像、[pixivimage:作品ID(-ページ)] はイラスト作品
    .replace(/\[uploadedimage:(\d+)\]/g, function (_, id) { return illustHTML(images.uploaded[id]); })
    .replace(/\[pixivimage:([\d-]+)\]/g, function (_, key) { return illustHTML(images.pixiv[key]); })
    // ページ内ジャンプは、ひとまず消しておく
    .replace(/\[jump:[^\]]*\]/g, "");
}

// 挿絵の場所の表を作る。
// 小説に上げた画像は本文データ (textEmbeddedImages) に入っている。
// イラスト作品の挿絵は、pixiv の画面と同じく /ajax/novel/{id}/insert_illusts に問い合わせる
function pixivImages(id, novel) {
    var images = { uploaded: {}, pixiv: {} };
    var embedded = novel.textEmbeddedImages || {};
    Object.keys(embedded).forEach(function (key) {
        var urls = embedded[key].urls || {};
        images.uploaded[key] = urls["1200x1200"] || urls["480mw"] || urls.original || "";
    });
    
    var keys = [];
    novel.content.replace(/\[pixivimage:([\d-]+)\]/g, function (_, key) {
        if (keys.indexOf(key) < 0) keys.push(key);
        return "";
    });
    if (keys.length === 0) return Promise.resolve(images);
    
    var query = keys.map(function (key) { return "id%5B%5D=" + encodeURIComponent(key); }).join("&");
    return fetch("/ajax/novel/" + encodeURIComponent(id) + "/insert_illusts?" + query, { credentials: "same-origin" })
    .then(function (response) { return response.json(); })
    .then(function (json) {
        var body = (json && !json.error && json.body) || {};
        keys.forEach(function (key) {
            var entry = body[key];
            var urls = entry && entry.visible && entry.illust && entry.illust.images;
            if (urls) images.pixiv[key] = urls.medium || urls.original || "";
        });
        return images;
    })
    // 問い合わせに失敗しても本文は読めるように、挿絵だけ諦める
    .catch(function () { return images; });
}

// シリーズの前の話・次の話へのリンク
function seriesNavHTML(nav) {
    if (!nav) return "";
    
    function link(item, label, className) {
        // 前（次）の話が無いときは、空の箱で場所だけ取っておく
        if (!item || !item.available) return '<span class="' + className + '"></span>';
        var url = "https://www.pixiv.net/novel/show.php?id=" + encodeURIComponent(item.id);
        // 内側の .__sr-face は、六角形の縁を描くための二枚重ねの内側 (ReaderMode.swift の CSS)
        return '<a class="' + className + '" href="' + url + '"><span class="__sr-face">' +
        "<small>" + label + "</small>" + escapeHTML(item.title) + "</span></a>";
    }
    
    return '<nav class="__sr-series">' +
    '<p class="__sr-series-title">' + escapeHTML(nav.title) + "</p>" +
    '<div class="__sr-series-links">' +
    link(nav.prev, "← 前の話", "__sr-prev") +
    link(nav.next, "次の話 →", "__sr-next") +
    "</div></nav>";
}

function extractPixivNovel(id, completion) {
    fetch("/ajax/novel/" + encodeURIComponent(id), { credentials: "same-origin" })
    .then(function (response) { return response.json(); })
    .then(function (json) {
        if (json.error || !json.body || !json.body.content) {
            throw new Error(json.message || "本文データがありません");
        }
        var novel = json.body;
        return pixivImages(id, novel).then(function (images) {
            var pages = novel.content.split("[newpage]");
            
            var html = pages.map(function (page, i) {
                // 2ページ目以降の頭に、ページ番号入りの区切りを置く
                var divider = i === 0 ? "" : '<div class="__sr-pagebreak" aria-hidden="true">' + (i + 1) + "</div>";
                // 前後の改行だけ削る（trim() だと行頭の全角スペースまで消えてしまう）
                var body = page.replace(/^\n+|\n+$/g, "");
                return divider + '<div class="__sr-novel-page">' + pixivPageToHTML(body, images) + "</div>";
            }).join("");
            
            html += seriesNavHTML(novel.seriesNavData);
            // 作者が勧める表示の向き (suggestedSettings.viewMode)。
            // pixiv の画面の決まりでは 0 = 既定 (横書き)、1 = 縦書き、2 = 横書き
            var settings = novel.suggestedSettings || {};
            completion({
                url: document.URL,
                title: novel.title || document.title,
                byline: novel.userName || "",
                siteName: "pixiv",
                lang: "ja",
                excerpt: "",
                length: novel.characterCount || novel.content.length,
                vertical: settings.viewMode === 1,
                content: html
            });
        });
    })
    .catch(function () {
        // 専用の抜き出しに失敗したら、汎用の抜き出しに任せる
        completion(extractGeneric());
    });
}

// ==== 入口 ====

// このページをリーダーで読めそうか (アドレスバーの本のボタンを出すかどうか)。抜き出しはせずに判定だけをする
function readerCheck() {
    return pixivNovelId() !== null || looksReadable(document);
}

// 本文を抜き出す。結果は { title, byline, siteName, lang, content, vertical, ... } か { error }
function readerExtract() {
    return new Promise(function (resolve) {
        var novelId = pixivNovelId();
        if (novelId) {
            extractPixivNovel(novelId, resolve);
        } else {
            extractGenericJoined(resolve);
        }
    });
}
