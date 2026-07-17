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
    private let identifier = "skyscraper.adblock.v1"

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
                return existing
            }
            // 無ければコンパイル（初回のみ。数百ms程度）
            return try? await store.compileContentRuleList(
                forIdentifier: id,
                encodedContentRuleList: Self.rulesJSON
            )
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
        "adingo\\.jp",
        "fout\\.jp",
        "microad\\.jp",
        "gmossp-sp\\.jp",
        "impact-ad\\.jp",
        "socdm\\.com",
        "deqwas\\.net",
        "logly\\.co\\.jp",
    ]

    // Safari コンテンツブロッカー形式の JSON を組み立てる
    private static var rulesJSON: String {
        var rules: [String] = []

        // 通信遮断ルール（1ドメイン1ルール。alternation | は使えないため）
        for domain in adDomains {
            rules.append("""
            {"trigger":{"url-filter":"\(domain)","load-type":["third-party"]},"action":{"type":"block"}}
            """)
        }

        // 見た目の掃除：AdSense の枠を非表示（通信遮断後に残る空枠対策）
        rules.append("""
        {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"ins.adsbygoogle"}}
        """)

        return "[" + rules.joined(separator: ",") + "]"
    }
}
