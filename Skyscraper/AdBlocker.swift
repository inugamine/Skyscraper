//
//  AdBlocker.swift
//  Skyscraper
//
//  広告・トラッカーの通信を WKContentRuleList で遮断する。
//  Safari のコンテンツブロッカーと同じ仕組み（WebKit エンジンレベル）。
//

import WebKit

@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    // ルールを変えたらここの番号を上げる。
    // 識別子が変わると古いコンパイル済みキャッシュを捨てて作り直す
    private let identifier = "skyscraper.adblock.v3"

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

    // MARK: - ルール本体

    // 主要な広告・トラッキング配信ドメイン。
    // url-filter は WebKit の限定正規表現なので、素直に「ドメイン名を含むか」で判定する。
    // load-type: third-party により、広告会社のサイト自体を開くことは妨げない
    private static let adDomains: [String] = [
        // Google 広告・計測
        "doubleclick\\.net",
        "googlesyndication\\.com",
        "googleadservices\\.com",
        "googletagservices\\.com",
        "adservice\\.google\\.com",
        "google-analytics\\.com",
        // タグマネージャ（広告スクリプトの搬入口）
        "googletagmanager\\.com",
        // 大手アドネットワーク
        "adnxs\\.com",
        "criteo\\.com",
        "criteo\\.net",
        "taboola\\.com",
        "outbrain\\.com",
        "pubmatic\\.com",
        "rubiconproject\\.com",
        "openx\\.net",
        "casalemedia\\.com",
        "smartadserver\\.com",
        "teads\\.tv",
        "33across\\.com",
        "bidswitch\\.net",
        "sharethrough\\.com",
        "amazon-adsystem\\.com",
        "adroll\\.com",
        "zedo\\.com",
        "adsrvr\\.org",
        // アドブロック対策（ad-recovery）の配信元
        "btloader\\.com",
        // 計測・スコアリング
        "scorecardresearch\\.com",
        "moatads\\.com",
        "adsafeprotected\\.com",
        "quantserve\\.com",
        "chartbeat\\.com",
        // 悪質系ポップアップ
        "popads\\.net",
        "propellerads\\.com",
        "exoclick\\.com",
        // 国内アドネットワーク
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

    // Safari コンテンツブロッカー形式の JSON を組み立てる。
    // 注意：文字列連結で組むと、正規表現の \. が JSON としては不正な
    // エスケープになり、コンパイルが丸ごと失敗する（JSON 上は \\. と
    // 二重化が必要）。エスケープは JSONSerialization に任せる
    private static var rulesJSON: String {
        // 通信遮断ルール（1ドメイン1ルール。alternation | は使えないため）
        var rules: [[String: Any]] = adDomains.map { domain in
            [
                "trigger": ["url-filter": domain, "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }

        // 見た目の掃除：通信遮断後に残る空枠を隠す。
        // AdSense の枠と、Google Ad Manager（GPT）のスロット
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": "ins.adsbygoogle, div[id^='div-gpt-ad'], iframe[id^='google_ads_iframe']",
            ],
        ])

        // YouTube のページ内広告枠（フィード内・マストヘッド・プレイヤー横）。
        // 動画広告自体は通信では止められないので、Tab 側の
        // youtubeAdSkipScript（プレイヤー監視）が受け持つ
        rules.append([
            "trigger": ["url-filter": ".*", "if-domain": ["*youtube.com"]],
            "action": [
                "type": "css-display-none",
                "selector": "ytd-display-ad-renderer, ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-banner-promo-renderer, #masthead-ad, #player-ads",
            ],
        ])

        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
