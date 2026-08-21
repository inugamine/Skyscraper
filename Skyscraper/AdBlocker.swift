//
//  AdBlocker.swift
//  Skyscraper
//
//  拡張機能（uBlock Origin Lite）が構造上できない後始末をする。
//
//  ── 分担 ──
//  通信の遮断は全部 uBOL の仕事だ。
//  EasyList / EasyPrivacy / Peter Lowe's に加え、設定画面から
//  AdGuard Japanese（jpn-1）を有効にしてあるので、
//  国内のアドネットワークも含めてこちらが手を出す必要はない。
//  リストの更新も uBOL 側で完結する。
//
//  では何が残るか。サイト固有の空枠だ。
//
//  通信が止まっても、枠を作っている div や section は DOM に残る。
//  min-height が直書きされていると、そこだけ真っ白に空く。
//  特に Google Ad Manager の div（id が div-gpt-ad-<数字>）は
//  公開フィルタリストが拾わない。id がサイトごとに違う上、
//  前方一致で潰すのは誤爆の危険があるからだろう。
//  自分専用のブラウザならその割り切りができる——それがここの価値だ。
//
//  ── YouTube には手を出さない ──
//
//  ここの整形ルールを当てると「広告ブロッカーは利用規約に違反しています」が出て
//  再生が止まる。css-display-none は WebKit が直に当てるので、
//  ページ側から getComputedStyle で覗けば「本来あるはずの枠が消えている」が
//  そのまま見える。JS で隠すより足跡が濃い。
//
//  切り分けで確かめた：uBOL を切り、プレイヤー監視（youtubeAdSkipScript）を
//  抜いた上でも、ここが生きている限り止まった。丸ごと外して初めて再生できた。
//
//  一方 uBOL は同じ遮断をしても通る。あちらは検知への対処を続けている。
//  追いかけっこに個人のブラウザで乗る意味は無いので、YouTube はあちらに任せ、
//  こちらは exceptDomains で自分から降りる
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
    private let identifier = "skyscraper.adblock.v6"

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

    // MARK: - 通信の遮断

    // 空。通信の遮断は全部 uBOL に任せている。
    //
    // 以前は国内アドネットワーク（i-mobile・microad・fluct・zucks・nend 等）
    // 22 件を自前で持っていたが、uBOL の AdGuard Japanese（jpn-1）を
    // 有効にしたことで不要になった。
    // 実測して、一覧を空にしても livedoor ・GIGAZINE などで
    // 広告の中身が一切出ないことを確かめてある（AdGuard Japanese は
    // 通信遮断 1911 件を持つ）。
    //
    // この配列は、今後 uBOL ではどうしても止まらない送信先が
    // 見つかった時のために残してある。
    //
    // 書き方：url-filter は WebKit の限定正規表現なので、
    // "example\\.com" のように「ドメイン名を含むか」で判定する。
    // alternation（|）は使えないので 1 ドメイン 1 ルール。
    // load-type: third-party により、その会社のサイト自体を開くことは妨げない
    private static let blockedDomains: [String] = []

    // MARK: - 空枠の掃除

    // 一件 = 一つの css-display-none ルール。
    // domains が nil なら全サイト、指定があればそのドメインだけに効く。
    //
    // 汎用的なクラス名は必ずドメインを限定すること。
    // ".ad-box" のような名前は、別のサイトで全く違う意味で使われている
    private struct Cosmetic {
        let selector: String
        var domains: [String]? = nil
        // 効かせない場所。YouTube のように、枠を隠すこと自体を
        // 見咎めてくるサイトを汎用ルールから外すために使う。
        // domains と同時には指定できない（下の組み立てを見ろ）
        var exceptDomains: [String]? = nil
    }

    private static let cosmeticRules: [Cosmetic] = [
        // ── どのサイトでも通用するもの ──
        //
        // AdSense の枠と、Google Ad Manager（GPT）のスロット。
        // GPT は div の id が div-gpt-ad-<数字> で固定なので前方一致で拾える。
        // min-height が直書きされていることが多く、隠さないと空白が残る。
        //
        // YouTube だけ外す。理由は冒頭に書いた——ここを当てると
        // 動画の再生そのものが止まる。あちらの広告は uBOL に任せる
        Cosmetic(selector: """
            ins.adsbygoogle, \
            div[id^='div-gpt-ad'], \
            iframe[id^='google_ads_iframe']
            """,
            exceptDomains: ["*youtube.com"]),

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
        var rules: [[String: Any]] = blockedDomains.map { domain in
            [
                "trigger": ["url-filter": domain, "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }

        // 空枠の掃除
        for rule in cosmeticRules {
            var trigger: [String: Any] = ["url-filter": ".*"]
            // if-domain と unless-domain は同居できない（WebKit が
            // ルールごと弾く）。片方だけを入れる
            if let domains = rule.domains {
                trigger["if-domain"] = domains
            } else if let except = rule.exceptDomains {
                trigger["unless-domain"] = except
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
