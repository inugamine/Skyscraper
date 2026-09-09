//
//  LinkHover.swift
//  Skyscraper
//
//  リンクの上に乗っている間、窓の左下に飛び先を出す帯。
//
//  実用の道具であると同時に、防具でもある。
//  「銀行のお知らせ」と書かれた文字列の下に別の宛先が仕込まれていても、
//  押す前に確かめる手立てがなければ利用者に見破りようがない。
//  ここはその手立てを用意する場所だ。
//
//  ── なぜ JS を撒くのか ──
//  macOS の WKWebView には「要素の上にマウスが乗った」を教える公開の口が無い。
//  _webView(_:mouseDidMoveOverElement:...) は動くが非公開で、
//  名前が変われば実行時に黙って死ぬ。踏まない。
//  代わりに各フレームへ小さな見張りを仕込み、乗った時だけ知らせてもらう。
//
//  ── 出し方の作法 ──
//  ただ URL を垂れ流すと、かえって騙しの片棒を担ぐ。
//  この帯が守る規則は四つ：
//   ・ホストだけを明るく、それ以外を沈める（部分域の偽装が浮く）
//   ・利用者情報部（user@）は警告色で晒す（隠すと "apple.com@evil.com" が通る）
//   ・省略は必ず後ろから（前を削るとホストが消える＝一番大事な所が消える）
//   ・javascript: と data: はスキーム名を明示する（宛先に見せかけた実行）
//
//  IDN（多言語ドメイン）は文字体系の混在で見る。詳しくは HostGuard の冒頭に書いた。
//

import SwiftUI
import WebKit

// MARK: - ページ側の見張り

enum LinkHover {
    static let messageHandlerName = "skyscraperLinkHover"

    // 全フレームに、他のスクリプトより先に仕込む。
    // 埋め込みの枠（iframe）の中のリンクも見たいので forMainFrameOnly は false
    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    // ページから届く知らせ
    struct Report: Equatable {
        // 飛び先。nil なら「今どのリンクにも乗っていない」
        var href: String?
        // 帯の下敷きになる辺りに居るか（帯を右へ逃がす合図）
        var nearBar: Bool
    }

    static func parse(_ body: Any) -> Report? {
        guard let dict = body as? [String: Any] else { return nil }
        let href = dict["href"] as? String
        let near = dict["near"] as? Bool ?? false
        // 空文字は「無し」と同じ扱いにする
        return Report(href: (href?.isEmpty ?? true) ? nil : href, nearBar: near)
    }

    private static let source = """
    (() => {
        if (window.__skyscraperLinkHoverInstalled) { return; }
        window.__skyscraperLinkHoverInstalled = true;

        // 直前に知らせた内容。同じものを送り続けない
        let last = null;

        const send = (href, near) => {
            const key = href === null ? '' : href + (near ? '#1' : '#0');
            if (key === last) { return; }
            last = key;
            window.webkit?.messageHandlers?.skyscraperLinkHover?.postMessage({
                href: href, near: near
            });
        };

        const clear = () => { send(null, false); };

        // href を絶対 URL にして返す。
        // HTML の a / area は el.href が解決済みの文字列で返る。
        // SVG の <a> は SVGAnimatedString（文字列ではない）なので自前で解く
        const hrefOf = (el) => {
            if (!el.hasAttribute || !el.hasAttribute('href')) { return null; }
            if (typeof el.href === 'string') { return el.href || null; }
            try {
                return new URL(el.getAttribute('href'), el.baseURI || document.baseURI).href;
            } catch (e) {
                return null;
            }
        };

        // 合成パスを辿って最初のリンクを拾う。
        // closest() ではなく composedPath() なのは Shadow DOM を貫くためだ。
        // 閉じた shadow root の中のリンクは closest からは見えない
        const anchorFrom = (event) => {
            const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
            for (const node of path) {
                if (!node || node.nodeType !== 1) { continue; }
                const tag = (node.tagName || '').toUpperCase();
                if (tag === 'A' || tag === 'AREA') { return node; }
            }
            const target = event.target;
            return (target && target.closest) ? target.closest('a[href], area[href]') : null;
        };

        // 帯の下敷きになる辺りか。
        // 帯は窓の左下に出るので、そこに重なるリンクに乗った時は右へ逃がす。
        // 入れ子の枠の中では窓の寸法が分からないので、そこでは判断しない
        const nearBar = (el) => {
            if (window.top !== window) { return false; }
            const rect = el.getBoundingClientRect();
            if (!rect.width && !rect.height) { return false; }
            return rect.bottom > window.innerHeight - 60
                && rect.left < window.innerWidth * 0.55;
        };

        const inspect = (event) => {
            const anchor = anchorFrom(event);
            if (!anchor) { clear(); return; }
            const href = hrefOf(anchor);
            if (!href) { clear(); return; }
            send(href, nearBar(anchor));
        };

        // mouseout は「離れた」の合図に使わない。
        // 子の要素をまたぐたびに飛んでくるので、出入りが入り乱れて手に負えない。
        // 乗るたびに現在地を見直し、リンクが無ければ消す方が確実だ
        document.addEventListener('mouseover', inspect, true);
        // Tab キーで辿っている時にも出す（キーボードだけで操る人にも同じ手立てを）
        document.addEventListener('focusin', inspect, true);

        // 窓の外へ出た時だけ消す。relatedTarget が空なのがその印
        document.addEventListener('mouseout', (event) => {
            if (!event.relatedTarget) { clear(); }
        }, true);

        window.addEventListener('blur', clear);
        window.addEventListener('pagehide', clear);
        // 画面を差し替える型のページ（SPA）用。
        // 本物の遷移はアプリ側が消すが、こちらは遷移として通知されない
        window.addEventListener('popstate', clear);
        window.addEventListener('hashchange', clear);
    })();
    """
}

// MARK: - 見せ方を決める

// 帯に出す文字列を、意味ごとに切り分けた形。
// 色分けはこの区切りがそのまま担う——描く側は判断しない
struct LinkHoverDisplay: Equatable {
    var scheme: String = ""       // "https://"。控えめに出す
    var credentials: String = ""  // "user@"。あれば警告色で晒す
    var host: String = ""         // ここだけ明るく出す
    var trail: String = ""        // 経路から後ろ。長ければ後ろを削る
    var warning: Warning?

    enum Warning: Equatable {
        case credentials  // 番地に人の名前が紛れている（偽装の常套手段）
        case punycode     // 見た目を偽れる符号化ホスト
        case script       // javascript:（宛先ではなく実行）
        case opaque       // data: / blob:（中身が番地に埋まっている）
    }

    var isEmpty: Bool {
        scheme.isEmpty && credentials.isEmpty && host.isEmpty && trail.isEmpty
    }
}

extension LinkHoverDisplay {
    // 後ろに残す長さの上限。ホストは何があっても削らない
    private static let trailLimit = 140

    static func make(from raw: String) -> LinkHoverDisplay {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return LinkHoverDisplay() }

        // URLComponents が匙を投げたら、生のまま出す。
        // 解けなかったことを黙って隠すより、読めるものを出す方がまし
        guard let parts = URLComponents(string: text) else {
            return LinkHoverDisplay(trail: clip(text))
        }

        let scheme = (parts.scheme ?? "").lowercased()

        // 宛先ではなく「実行」の類。スキーム名を必ず先頭に立てる
        switch scheme {
        case "javascript":
            return LinkHoverDisplay(scheme: "javascript:",
                                    trail: clip(dropScheme(text, "javascript:")),
                                    warning: .script)
        case "data", "blob":
            return LinkHoverDisplay(scheme: scheme + ":",
                                    trail: clip(dropScheme(text, scheme + ":")),
                                    warning: .opaque)
        default:
            break
        }

        // ホストが無い型（mailto: tel: file: など）。強調する所が無いので素直に出す
        guard let rawHost = parts.host, !rawHost.isEmpty else {
            return LinkHoverDisplay(scheme: scheme.isEmpty ? "" : scheme + ":",
                                    trail: clip(dropScheme(text, scheme + ":")))
        }

        var display = LinkHoverDisplay()
        display.scheme = scheme.isEmpty ? "" : scheme + "://"

        // 利用者情報部。ここが本命の落とし穴だ。
        // "https://www.mybank.example.com@evil.test/" の飛び先は evil.test であって
        // mybank ではない。隠すと騙しに加担するので、警告色で必ず出す。
        // 合言葉の方は伏せる（肩越しに見られる方が困る）
        if let user = parts.user, !user.isEmpty {
            display.credentials = parts.password == nil ? user + "@" : user + ":****@"
            display.warning = .credentials
        }

        // ホストの検分。紛らわしい綴りなら符号化した姿に戻して返る
        let verdict = HostGuard.inspect(rawHost.lowercased())
        var host = verdict.host
        if let port = parts.port { host += ":\(port)" }
        display.host = host
        // 利用者情報部の警告の方が重い。既に立っていれば譲る
        if display.warning == nil { display.warning = verdict.warning }

        var trail = parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { trail += "?" + query }
        if let fragment = parts.percentEncodedFragment { trail += "#" + fragment }
        // "/" だけの経路は出さない。帯が無駄に賑やかになる
        display.trail = trail == "/" ? "" : clip(trail)

        return display
    }

    // 後ろから削る。前を削るとホストが消える＝見破る手立てが消える
    private static func clip(_ text: String) -> String {
        guard text.count > trailLimit else { return text }
        return String(text.prefix(trailLimit)) + "…"
    }

    private static func dropScheme(_ text: String, _ scheme: String) -> String {
        guard text.lowercased().hasPrefix(scheme.lowercased()) else { return text }
        return String(text.dropFirst(scheme.count))
    }
}

// MARK: - ホストの検分

// 見た目で人を騙すホスト名を暴く。
//
// 当初は "xn--" という接頭辞を探していたが、それは空振りだった。
// href が届く時点か、URLComponents を通した時点で、符号化は既に解けている。
// xn--pple-43d.com は "аpple.com" として、本物と一字も違わない姿で帯に出ていた。
// 接頭辞を探す限り、この手の偽装は必ず素通りする。
//
// なので文字そのものを見る。ラテン文字の中にキリル文字や
// ギリシア文字が紛れ込んでいれば、それは読ませるためではなく騙すための混ぜ方だ。
// 疑わしいものは符号化した姿（xn--pple-43d.com）に戻して出す——
// 読みにくいのは承知の上で、その読みにくさ自体が警告になる。
//
// 一方で、日本語のドメイン（総務省.jp の類）は漢字・仮名・英数字が
// 混ざるのが普通だ。そこを符号化して出すのは単なる嫌がらせなので通す。
// UTS 39 の Highly Restrictive に倣った線引きだ。
//
// 残っている穴：全ての文字が一つの体系で揃った偽装
//（キリル文字だけで綴った "аррӏе" のような類）は、
// 体系の混在が起きないので抜ける。そこまで見るには同形異義の対応表が要る。
enum HostGuard {
    struct Verdict {
        // 帯に出すホスト（疑わしければ符号化されている）
        var host: String
        var warning: LinkHoverDisplay.Warning?
    }

    static func inspect(_ host: String) -> Verdict {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        // 全て ASCII 。既に符号化された姿で届いた場合もここだ。
        // 中身は読めないが、姿そのものに曖昧さが無いのでそのまま出し、印だけ付ける
        guard host.unicodeScalars.contains(where: { $0.value >= 0x80 }) else {
            let encoded = labels.contains { $0.hasPrefix("xn--") }
            return Verdict(host: host, warning: encoded ? .punycode : nil)
        }

        guard labels.contains(where: isDeceptive) else {
            // 素直な多言語ドメイン。読める姿のまま出す
            return Verdict(host: host, warning: nil)
        }
        return Verdict(host: labels.map(punycode).joined(separator: "."),
                       warning: .punycode)
    }

    // MARK: 文字体系の混在

    private enum Script {
        case latin, cyrillic, greek, cjk, hangul, other
    }

    // 数字と区切りはどの体系にも属さないので nil を返す（数えない）
    private static func script(of scalar: UnicodeScalar) -> Script? {
        switch scalar.value {
        case 0x30...0x39, 0x2D, 0x5F:
            return nil
        case 0x41...0x5A, 0x61...0x7A, 0x00C0...0x024F, 0x1E00...0x1EFF:
            return .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0400...0x052F:
            return .cyrillic
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return .cjk
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            return .hangul
        default:
            return .other
        }
    }

    private static func isDeceptive(_ label: String) -> Bool {
        var scripts: Set<Script> = []
        for scalar in label.precomposedStringWithCanonicalMapping.unicodeScalars {
            if let script = script(of: scalar) { scripts.insert(script) }
        }
        // 一つの体系で揃っているなら、少なくとも「混ぜた」痕は無い
        if scripts.count <= 1 { return false }
        // 日本語・韓国語のドメインは英数字と混ざるのが普通だ。そこは通す
        if scripts == [.latin, .cjk] || scripts == [.latin, .hangul] { return false }
        return true
    }

    // MARK: Punycode 符号化（RFC 3492）

    // Foundation には公開の口が無いので自前で組む。
    // 復号は要らない（読める姿は既に手元にある）
    private static let base: UInt32 = 36
    private static let tmin: UInt32 = 1
    private static let tmax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700

    static func punycode(_ label: String) -> String {
        let normalized = label.precomposedStringWithCanonicalMapping.lowercased()
        let input = Array(normalized.unicodeScalars)
        guard input.contains(where: { $0.value >= 0x80 }) else { return normalized }
        // DNS のラベルは 63 文字まで。超えるものは扱わずそのまま返す
        guard input.count <= 63 else { return normalized }

        var output = input.filter { $0.value < 0x80 }.map { Character($0) }
        let basic = UInt32(output.count)
        if basic > 0 { output.append("-") }

        var handled = basic
        var n: UInt32 = 128
        var delta: UInt32 = 0
        var bias: UInt32 = 72
        let total = UInt32(input.count)

        while handled < total {
            var m = UInt32.max
            for scalar in input where scalar.value >= n { m = min(m, scalar.value) }
            delta += (m - n) * (handled + 1)
            n = m
            for scalar in input {
                if scalar.value < n { delta += 1 }
                guard scalar.value == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, points: handled + 1, first: handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return "xn--" + String(output)
    }

    // 0–25 → a–z、26–35 → 0–9
    private static func digit(_ value: UInt32) -> Character {
        let v = value % base
        let scalar = v < 26 ? UnicodeScalar(0x61 + v)! : UnicodeScalar(0x30 + v - 26)!
        return Character(scalar)
    }

    private static func adapt(_ delta: UInt32, points: UInt32, first: Bool) -> UInt32 {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k: UInt32 = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= (base - tmin)
            k += base
        }
        return k + (((base - tmin + 1) * delta) / (delta + skew))
    }
}

// MARK: - 帯の形

// 左下に据える帯。左辺と下辺は窓の縁に接するので描かず、
// 右端を斜めに落として楔にする。段々ビルの裾と同じ理屈だ
private struct LinkHoverBarShape: Shape {
    var cut: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cut = min(cut, rect.width)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// 縁取りは見えている辺だけ。窓の縁に接する二辺に線を引くと二重に見える
private struct LinkHoverBarEdge: Shape {
    var cut: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cut = min(cut, rect.width)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

// MARK: - 帯

struct LinkHoverBar: View {
    let display: LinkHoverDisplay
    // 帯の下にリンクが居る時は右へ逃がす
    var flipped: Bool = false

    private var hostColor: Color {
        display.warning == .punycode ? Deco.rust : Deco.cream
    }

    // 各段に色を付けて一本に綴じる。
    // 別々の Text を HStack で並べると、詰まった時に切れる場所を選べない。
    // 一本にしておけば truncationMode(.tail) が後ろから削ってくれる
    private var styled: AttributedString {
        var out = AttributedString()
        out += segment(display.scheme, Deco.dimGold)
        out += segment(display.credentials, Deco.rust)
        out += segment(display.host, hostColor)
        out += segment(display.trail, Deco.dimGold)
        return out
    }

    private func segment(_ text: String, _ color: Color) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = color
        return piece
    }

    var body: some View {
        HStack(spacing: 5) {
            if let warning = display.warning {
                Triangle()
                    .stroke(warningColor(warning), lineWidth: 1)
                    .frame(width: 9, height: 8)
            }

            Text(styled)
                .font(.system(size: 11, design: .serif))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // 斜めに落とした分の逃げ。裏返せば楔も反対側へ回るので、寄せる先も入れ替える
        .padding(flipped ? .leading : .trailing, 8)
        .background(
            ZStack {
                LinkHoverBarShape().fill(Deco.ink.opacity(0.95))
                LinkHoverBarEdge().stroke(Deco.gold.opacity(0.55), lineWidth: 1)
            }
            .scaleEffect(x: flipped ? -1 : 1)  // 右下へ回す時は形だけ裏返す
        )
        // 飾りは触られない。下のリンクを押す邪魔をしない
        .allowsHitTesting(false)
    }

    private func warningColor(_ warning: LinkHoverDisplay.Warning) -> Color {
        switch warning {
        // 符号化ホストは「読みにくい」ではなく「騙されかけている」の印だ。
        // 利用者情報部の警告と同じ重みで出す
        case .credentials, .script, .punycode: return Deco.rust
        case .opaque:                          return Deco.dimGold
        }
    }
}

// MARK: - 差し込み口

extension View {
    // ページの上に帯を重ねる。display が nil の間は何も出さない。
    //
    // animation を重ねる先が overlay の内側なのは、下地が WebView だからだ。
    // 外側に掛けると、帯が出入りするたびに Web の中身まで
    // 「変わったもの」として巻き添えで動かされる
    func linkHoverBar(_ display: LinkHoverDisplay?, flipped: Bool) -> some View {
        overlay(alignment: flipped ? .bottomTrailing : .bottomLeading) {
            ZStack {
                if let display, !display.isEmpty {
                    LinkHoverBar(display: display, flipped: flipped)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: display)
        }
    }
}
