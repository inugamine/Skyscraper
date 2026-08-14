//
//  AdBlocker.swift
//  Skyscraper
//
//  拡張機能（uBlock Origin Lite）の穴を埋める、国内向けの補完ルール。
//
//  ── 分担 ──
//  通信の遮断そのものは uBOL が受け持つ。あちらは EasyList / EasyPrivacy /
//  Peter Lowe's list を内蔵し、WebKit が DNR をエンジンレベルで実行する
//  （変換済みのルールは 120MB 規模になる）。追加も更新も自動だ。
//
//  だが、それでも二つ穴が残る。
//
//  1. 国内アドネットワーク
//     uBOL の既定で有効なリストは欧米向けで、日本語圏の配信元は薄い。
//     AdGuard Japanese 相当のリストは uBOL に同梱されているが「既定で無効」で、
//     有効にするには拡張のポップアップ画面が要る。
//     Skyscraper はまだ拡張のポップアップを出せない（WKWebExtensionTab には
//     準拠したが、popup の表示は未実装）ので、ここで自前で持つ。
//     ポップアップを出せるようになったら、この一覧は捨ててよくなる。
//
//  2. サイト固有の空枠
//     通信が止まっても、枠を作っている div や section は DOM に残る。
//     min-height が直書きされていると、そこだけ真っ白に空く。
//     EasyList にも uBOL にも、日本のサイト固有のクラス名は入っていない。
//     ここが今のこのファイルの主戦場だ。
//
//  ── 育て方 ──
//  普段見るサイトで空枠が残っていたら、Web インスペクタで要素を掴んで
//  cosmeticRules に一行足す。ドメイン一覧を追いかけるより効果が見える。
//  誤爆を避けるため、汎用的なクラス名（.ad-box など）は必ず if-domain で
//  サイトを限定すること。
//

import WebKit

@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    // ルールを変えたらここの番号を上げる。
    // 識別子が変わると古いコンパイル済みキャッシュを捨てて作り直す
    private let identifier = "skyscraper.adblock.v4"

    private var cached: WKContentRuleList?
    private var compileTask: Task<WKContentRuleList?, Never>?

    private init() {}

    // コンパイル済みルール一式を返す。初回だけコンパイルし、以後はキャッシュ。
    // 複数タブが同時に呼んでも、コンパイルは一度しか走らない
    func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        if let task = compileTask { return await task.value }

        let id = identifier
        let task = Task<WKContentRuleList?, Never> {
            guard let store = WKContentRuleListStore.default() else { return nil }
            // 前回起動時のコンパイル済みキャッシュがあればそれを使う
            // （見つからないときは throw されるので try? で拾う）
            if let existing = try? await store.contentRuleList(forIdentifier: id) {
                print("AdBlocker: using cached rule list (\(id))")
                return existing
            }
            // 無ければコンパイル（初回のみ。数百ms程度）。
            // 失敗を握り潰すと無言で素通しになるので、必ずログに残す
            do {
                let list = try await store.compileContentRuleList(
                    forIdentifier: id,
                    encodedContentRuleList: Self.rulesJSON
                )
                print("AdBlocker: compiled rule list (\(id))")
                return list
            } catch {
                print("AdBlocker: compile FAILED (\(id)): \(error)")
                return nil
            }
        }
        compileTask = task
        let list = await task.value
        cached = list
        return list
    }

    // WebView にルールを適用する。Tab の init から呼ぶ
    func apply(to webView: WKWebView) {
        Task { [weak webView] in
            guard let list = await AdBlocker.shared.ruleList() else { return }
            webView?.configuration.userContentController.add(list)
            // 適用前に読み込み済みのページには効かないので、必要ならリロードで反映される
        }
    }

    // MARK: - 通信の遮断（国内アドネットワークのみ）

    // 海外の大手（doubleclick / criteo / taboola / outbrain / pubmatic 等）は
    // uBOL の EasyList と完全に重複するので持たない。
    // ここに残すのは、uBOL の既定リストが手薄な日本語圏の配信元だけだ。
    //
    // url-filter は WebKit の限定正規表現なので、素直に「ドメイン名を含むか」で判定する。
    // load-type: third-party により、広告会社のサイト自体を開くことは妨げない
    private static let domesticAdDomains: [String] = [
        "i-mobile\\.co\\.jp",
        "im-apps\\.net",
        "adingo\\.jp",
        "fluct\\.jp",
        "fout\\.jp",
        "microad\\.jp",
        "gmossp-sp\\.jp",
        "impact-ad\\.jp",
        "socdm\\.com",
        "deqwas\\.net",
        "logly\\.co\\.jp",
        "gsspcln\\.jp",
        "gssprt\\.jp",
        "zucks\\.net",
        "nend\\.net",
        "ad-stir\\.com",
        "yieldone\\.com",
        "fam-ad\\.com",
        "yads\\.c\\.yimg\\.jp",
        // レコメンド型広告（記事下の「おすすめ」風の枠）
        "popin\\.cc",
        "dable\\.io",
        "speee-ad\\.jp",
    ]

    // MARK: - 空枠の掃除

    // 一件 = 一つの css-display-none ルール。
    // domains が nil なら全サイト、指定があればそのドメインだけに効く。
    //
    // 汎用的なクラス名は必ずドメインを限定すること。
    // ".ad-box" のような名前は、別のサイトで全く違う意味で使われている
    private struct Cosmetic {
        let selector: String
        var domains: [String]? = nil
    }

    private static let cosmeticRules: [Cosmetic] = [
        // ── どのサイトでも通用するもの ──
        //
        // AdSense の枠と、Google Ad Manager（GPT）のスロット。
        // GPT は div の id が div-gpt-ad-<数字> で固定なので前方一致で拾える。
        // min-height が直書きされていることが多く、隠さないと空白が残る
        Cosmetic(selector: """
            ins.adsbygoogle, \
            div[id^='div-gpt-ad'], \
            iframe[id^='google_ads_iframe']
            """),

        // ── YouTube ──
        // ページ内の広告枠（フィード内・マストヘッド・プレイヤー横）。
        // 動画広告自体は通信では止められないので、Tab 側の
        // youtubeAdSkipScript（プレイヤー監視）が受け持つ
        Cosmetic(selector: """
            ytd-display-ad-renderer, \
            ytd-ad-slot-renderer, \
            ytd-in-feed-ad-layout-renderer, \
            ytd-banner-promo-renderer, \
            #masthead-ad, \
            #player-ads
            """,
            domains: ["*youtube.com"]),

        // ── livedoor ──
        // 右カラムの 300×250 と、記事一覧の下に並ぶ枠。
        // どちらもサイト固有のクラス名で、EasyList にも uBOL にも無い
        Cosmetic(selector: "section.side-premium, section.ad-box",
                 domains: ["*livedoor.com"]),
    ]

    // MARK: - ルールの組み立て

    // Safari コンテンツブロッカー形式の JSON を組み立てる。
    // 注意：文字列連結で組むと、正規表現の \. が JSON としては不正な
    // エスケープになり、コンパイルが丸ごと失敗する（JSON 上は \\. と
    // 二重化が必要）。エスケープは JSONSerialization に任せる
    private static var rulesJSON: String {
        // 通信遮断ルール（1ドメイン1ルール。alternation | は使えないため）
        var rules: [[String: Any]] = domesticAdDomains.map { domain in
            [
                "trigger": ["url-filter": domain, "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }

        // 空枠の掃除
        for rule in cosmeticRules {
            var trigger: [String: Any] = ["url-filter": ".*"]
            if let domains = rule.domains {
                trigger["if-domain"] = domains
            }
            rules.append([
                "trigger": trigger,
                "action": [
                    "type": "css-display-none",
                    "selector": rule.selector,
                ],
            ])
        }

        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
