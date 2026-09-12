//
//  Geolocation.swift
//  Skyscraper
//
//  ページに現在地を渡す係。サイトごとの許可も、ここで預かる。
//
//  ── なぜ自前で作るのか ──
//  macOS の WKWebView は navigator.geolocation を持ってはいる。
//  だが getCurrentPosition() を叩くと code:1 "User denied Geolocation" が
//  即座に返るだけだ。WebKit の側に「許可を出す係」を差し込む口が要るのだが、
//  その口は公開されていない（iOS の requestGeolocationPermissionFor に
//  相当するものが macOS の WKUIDelegate に無い。Safari は非公開の
//  WKGeolocationManagerSetProvider を使っている）。
//  非公開の口は名前が変われば実行時に黙って死ぬので踏まない。
//
//  そこで navigator.geolocation を丸ごと自前の実装に差し替える。
//  WebKit 本来の実装は一度も呼ばれなくなるので、
//  「アプリの許可」と「サイトの許可」で二度訊かれる事故も起きない。
//
//  ── 訊く順番 ──
//  ① こちらのダイアログ（このサイトに渡してよいか）
//  ② macOS の位置情報の許可（初回だけ。CoreLocation が出す）
//  この順でなければならない。逆にすると、サイトを断るつもりの利用者から
//  先に OS の許可だけ取り上げることになる。
//
//  ── 期限と精度はページ側で捌く ──
//  timeout / maximumAge は下の JS が持つ。仕様上どちらも
//  「呼び出し側の都合」であって現在地の取得方法とは関係が無い。
//  こちらへ持ち込むと、依頼ごとに別の時計を native 側で回す羽目になる。
//

import AppKit
import CoreLocation
import Combine
import Foundation
import WebKit

// MARK: - サイトごとの許可を預かる

@MainActor
final class GeolocationStore: ObservableObject {
    static let shared = GeolocationStore()

    // 設定画面のトグルと共有する鍵。既定は「サイトごとに訊く」
    static let enabledKey = "skyscraper.geolocation"

    private let storageKey = "skyscraper.geolocationPermissions.v1"

    // "https://example.com" → 許可したか
    private var decisions: [String: Bool]

    // プライベートウィンドウでの記憶。メモリだけで、最後の一枚を閉じた時に捨てる。
    //
    // 読むのは上の decisions からも読む（通常で許したサイトはプライベートでも許す。
    // Safari も Chrome もそうしている）。書くのはこちらだけ——痕跡を残さない
    private var sessionDecisions: [String: Bool] = [:]

    private init() {
        decisions = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Bool] ?? [:]
    }

    // 非常停止装置。切られていればページには一律 code:1 を返す。
    //
    // @AppStorage の既定値と揃える。鍵が無い＝まだ触られていない
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var hasSavedDecisions: Bool { !decisions.isEmpty }

    // 覚えた許可をすべて忘れる（設定画面から呼ぶ）
    func reset() {
        decisions.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // その場所について覚えていること。nil なら未設定（次に訊く）。
    //
    // プライベート（.session）ならセッションの記憶を先に見る。
    // permissions.query の答えにも使う——あれはダイアログを出さずに「今どうか」だけを返す
    func decision(origin: String, scope: DataScope) -> Bool? {
        if !scope.isPersistent, let saved = sessionDecisions[origin] { return saved }
        return decisions[scope.key(origin)]
    }

    // その場所の記憶だけを忘れる。他のサイトには手を触れない
    func forget(origin: String, scope: DataScope) {
        guard decisions.removeValue(forKey: scope.key(origin)) != nil else { return }
        UserDefaults.standard.set(decisions, forKey: storageKey)
    }

    // プライベートの記憶を捨てる。最後のプライベートウィンドウが閉じた時に呼ばれる
    func forgetSession() {
        sessionDecisions.removeAll()
    }

    // MARK: - 判断

    // scope が .session ならプライベートウィンドウ。記憶はメモリにしか書かない。
    // .profile なら鍵に印が付くので、他のプロファイルの記憶とは混ざらない
    func decide(origin: String, host: String, in window: NSWindow?, scope: DataScope) async -> Bool {
        guard isEnabled else { return false }

        if let saved = decision(origin: origin, scope: scope) { return saved }

        let persistent = scope.isPersistent
        let (allowed, remember) = await ask(host: host, in: window, persistent: persistent)
        if remember {
            if persistent {
                decisions[scope.key(origin)] = allowed
                UserDefaults.standard.set(decisions, forKey: storageKey)
            } else {
                sessionDecisions[origin] = allowed
            }
        }
        return allowed
    }

    // MARK: - 問い合わせダイアログ

    // 作法は MediaPermission と揃える。
    // 既定のボタンは「許可しない」——Return を叩いただけで現在地は出さない
    private func ask(host: String, in window: NSWindow?, persistent: Bool) async -> (allowed: Bool, remember: Bool) {
        let site = host.isEmpty ? String(localized: "This site") : host

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "“\(site)” would like to know your location.")
        alert.informativeText = String(localized: "Allow this only if you trust the site.")

        let allow = alert.addButton(withTitle: String(localized: "Allow"))
        let deny  = alert.addButton(withTitle: String(localized: "Don't Allow"))
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\r"

        alert.showsSuppressionButton = true
        // プライベートでは「記憶する」の射程が違う。永続に見える文言は使わない
        alert.suppressionButton?.title = persistent
            ? String(localized: "Remember my choice for this site")
            : String(localized: "Remember until all private windows are closed")

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }

        return (response == .alertFirstButtonReturn,
                alert.suppressionButton?.state == .on)
    }

    // MARK: - 鍵の組み立て

    // WKSecurityOrigin から保存用の鍵を組む。
    //
    // 既定のポートは 0 で差し出されるので "https://example.com" には
    // ポートが付かない。URL 版（下）と形が揃っていないと
    // 「覚えているはずなのに毎回訊かれる」になる。
    // MediaPermission.swift の同名関数と同じ作法だ
    static func storageOrigin(_ origin: WKSecurityOrigin) -> String {
        let scheme = origin.`protocol`
        var text = scheme.isEmpty ? origin.host : "\(scheme)://\(origin.host)"
        if origin.port != 0 { text += ":\(origin.port)" }
        return text
    }

    static func storageOrigin(for url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return "" }
        let scheme = (url.scheme ?? "").lowercased()
        var text = scheme.isEmpty ? host : "\(scheme)://\(host)"
        if let port = url.port { text += ":\(port)" }
        return text
    }

    // 安全な文脈か。
    //
    // 仕様では https と、手元（localhost / 127.0.0.1 / ::1）と file: が該当する。
    // 平文の http に現在地を渡すと、同じ回線に居る誰にでも読まれる
    static func isSecure(_ origin: WKSecurityOrigin) -> Bool {
        isSecure(scheme: origin.`protocol`, host: origin.host)
    }

    // 同じ判定を URL からもできるようにする。
    //
    // 安全な文脈かどうかは、要求元の枠だけでは決まらない。
    // 平文のページに埋まった https の枠は、仕様上安全な文脈ではない
    //（祖先が一つでも平文なら、その中は全て巻き添えを食う）。
    // だから最上位と両方で見る
    static func isSecure(for url: URL) -> Bool {
        isSecure(scheme: url.scheme ?? "", host: url.host() ?? "")
    }

    private static func isSecure(scheme: String, host: String) -> Bool {
        let scheme = scheme.lowercased()
        if scheme == "https" || scheme == "file" { return true }
        guard scheme == "http" else { return false }
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" || host == "[::1]" { return true }

        // 127.0.0.0/8 は全域がループバック。
        // 綴りで比べると 127.0.0.1 しか拾えない（HTTPSFirstStore.isExempt と同じ帯判定）
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && Int(parts[0]) == 127
            && parts.dropFirst().allSatisfy { Int($0) != nil }
    }
}

// MARK: - 現在地を取りに行く（タブごとに一人）

@MainActor
final class GeolocationProvider: NSObject {

    static let messageHandlerName = "skyscraperGeolocation"

    // 器は wire() で差し替わる。強く持つとタブが解けない
    weak var webView: WKWebView?

    // このタブの記憶の射程。wire() でタブから入れられる。
    // 以前は置き場の isPersistent を見ていたが、プロファイルはそれでは見分けられない
    var scope: DataScope = .default

    private let manager = CLLocationManager()

    // 待たせている依頼。
    //
    // 一発取り（getCurrentPosition）は届けたら消す。
    // 継続（watchPosition）は clearWatch が来るまで残す。
    // 同じ配列に入れず分けてあるのは、CLLocationManager 側の
    // 止め方が違うからだ（requestLocation は一回で自分から止まる）
    private struct Pending {
        let id: Int
        let frame: WKFrameInfo
        let highAccuracy: Bool
    }
    private var oneShots: [Pending] = []
    private var watches: [Pending] = []

    // 同じサイトから連打された時、ダイアログを何枚も重ねない。
    // 一枚目の答えが出るまで後続は待たせる
    private var askingOrigins: Set<String> = []

    // ── Permissions-Policy ヘッダの控え ──
    //
    // 応答の URL（フラグメントを除く）→ その文書が geolocation を誰に許しているか。
    // サーバが自分の文書に対して「位置情報は使わせない」と宣言できる。
    // これを見ないと、サイトの意思に反して許可を訊いてしまう。
    //
    // 引く鍵は frame.request.url——WebKit が握っている値で、ページ側から偽装できない
    private var headerPolicies: [String: HeaderPolicy] = [:]

    enum HeaderPolicy {
        case none               // geolocation=()　誰にも許さない
        case all                // geolocation=*
        case list([String])     // 列挙。"self" はそのままの綴りで入る
    }

    // 応答が届いた。geolocation の指定があれば控える。
    //
    // 主フレームの応答なら前のページの分は捨てる。
    // タブを使い続けても控えが肥えないように
    func recordPolicy(from response: HTTPURLResponse, isMainFrame: Bool) {
        if isMainFrame { headerPolicies.removeAll() }
        guard let url = response.url,
              let raw = response.value(forHTTPHeaderField: "Permissions-Policy"),
              let policy = Self.parseGeolocationPolicy(raw)
        else { return }
        headerPolicies[Self.documentKey(url)] = policy
    }

    // この文書は、自分のヘッダで geolocation を自分に許しているか。
    // ヘッダが無ければ既定値（self）で許される
    private func headerAllows(documentURL: URL?) -> Bool {
        guard let documentURL,
              let policy = headerPolicies[Self.documentKey(documentURL)]
        else { return true }

        switch policy {
        case .none: return false
        case .all:  return true
        case .list(let entries):
            let own = GeolocationStore.storageOrigin(for: documentURL)
            return entries.contains { $0 == "self" || (!own.isEmpty && $0 == own) }
        }
    }

    private static func documentKey(_ url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? url.absoluteString
    }

    // この文書のヘッダは、childOrigin の枠へ geolocation を委ねることを許しているか。
    //
    // 仕様の「継承されるポリシー」の一段。親がヘッダで geolocation を宣言していれば、
    // その許可リストに子のオリジンが無い限り、allow 属性で何を書いても子は通らない。
    // 宣言していなければこの段は飛ばされる（allow 属性と既定値だけで決まる）
    func headerAllowsDelegation(from documentURL: URL?, to childOrigin: String) -> Bool {
        guard let documentURL,
              let policy = headerPolicies[Self.documentKey(documentURL)]
        else { return true }

        switch policy {
        case .none: return false
        case .all:  return true
        case .list(let entries):
            let own = GeolocationStore.storageOrigin(for: documentURL)
            return entries.contains { entry in
                (entry == "self" && !own.isEmpty && childOrigin == own) || entry == childOrigin
            }
        }
    }

    // ヘッダの値から geolocation の分だけを読む。指定が無ければ nil。
    //
    // 形は Structured Fields の辞書だ:
    //   geolocation=(self "https://a.example"), camera=()
    //   geolocation=*
    // 厳密な構文解析はしない。読めないものは「誰にも許さない」に倒す——
    // サーバが制限を書こうとしたことだけは確かなので、緩める方には倒さない
    static func parseGeolocationPolicy(_ header: String) -> HeaderPolicy? {
        for member in header.split(separator: ",") {
            let text = member.trimmingCharacters(in: .whitespaces)
            guard let eq = text.firstIndex(of: "=") else { continue }
            let name = text[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "geolocation" else { continue }

            let value = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value == "*" { return .all }
            guard value.hasPrefix("("), value.hasSuffix(")") else { return HeaderPolicy.none }

            let inner = value.dropFirst().dropLast()
            let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
            if tokens.isEmpty { return HeaderPolicy.none }
            if tokens.contains("*") { return .all }
            // 列挙された URL はオリジンの形に揃えておく（比較は storageOrigin 同士）
            let normalized = tokens.map { token -> String in
                if token == "self" { return token }
                guard let u = URL(string: token) else { return token }
                let o = GeolocationStore.storageOrigin(for: u)
                return o.isEmpty ? token : o
            }
            return .list(normalized)
        }
        return nil
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: - ページからの依頼

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let id = body["id"] as? Int
        else { return }

        let frame = message.frameInfo

        if kind == "clear" {
            watches.removeAll { $0.id == id }
            stopIfIdle()
            return
        }

        // permissions.query からの問い。ダイアログは出さず、今の状態だけを返す
        let isQuery = kind == "query"

        let highAccuracy = body["highAccuracy"] as? Bool ?? false

        // 出所はページの申告ではなく WebKit が握っている frameInfo から取る。
        // ページに名乗らせれば、いくらでも他所のサイトを騙れる
        let frameOrigin = frame.securityOrigin

        // 最上位の行き先。記憶もダイアログもこちらに付ける
        guard let topURL = webView?.url else {
            if isQuery { pushQuery(id: id, to: frame, state: "denied"); return }
            deliverError(id: id, to: frame, code: 2,
                         message: "Could not determine your location.")
            return
        }

        // 安全な文脈かは、要求元の枠と最上位の両方で見る
        guard GeolocationStore.isSecure(frameOrigin),
              GeolocationStore.isSecure(for: topURL)
        else {
            if isQuery { pushQuery(id: id, to: frame, state: "denied"); return }
            deliverError(id: id, to: frame, code: 1,
                         message: "Geolocation requires a secure connection.")
            return
        }

        // 記憶もダイアログも最上位のオリジンに付ける。
        //
        // 利用者の頭の中は「このサイトを許可した」だからだ。
        // 埋め込み側のオリジンで覚えると、同じ広告網が
        // 別のサイトでも許可済みになってしまう。
        //
        // 主フレームしか注入していない間は、これは
        // frameInfo から取るのと完全に同じ値になる（保存済みもそのまま使える）
        let key = GeolocationStore.storageOrigin(for: topURL)
        let host = topURL.host() ?? ""

        Task { @MainActor in
            // 門番に訊く。ここを通らない限りダイアログも出さない。
            //
            // 最上位も短絡せずに通す。短絡させると、門番が壊れた時に
            // 「枠の中だけ静かに死ぬ」形になって気づけない。
            // 全部通しておけば、壊れた時は即座に分かる
            guard await isAllowed(in: frame) else {
                if isQuery { pushQuery(id: id, to: frame, state: "denied"); return }
                deliverError(id: id, to: frame, code: 1,
                             message: "Geolocation is not allowed in this frame.")
                return
            }

            // 誰の分として覚えるかはタブが決める（プライベート・プロファイル・既定）
            let scope = self.scope

            // 問いならここで答えて終わる。記憶が無ければ prompt——
            // 「訊けばダイアログが出る」という意味で、仕様通りだ
            if isQuery {
                let state: String
                if !GeolocationStore.shared.isEnabled {
                    state = "denied"
                } else if let saved = GeolocationStore.shared.decision(origin: key, scope: scope) {
                    state = saved ? "granted" : "denied"
                } else {
                    state = "prompt"
                }
                pushQuery(id: id, to: frame, state: state)
                return
            }

            // 一枚目のダイアログが出ている間は、同じサイトの後続を待たせる。
            // 待った先で答えが出ていれば decide は訊かずに返す
            while askingOrigins.contains(key) {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            let known = GeolocationStore.shared.decision(origin: key, scope: scope) != nil
            if !known { askingOrigins.insert(key) }
            let allowed = await GeolocationStore.shared.decide(
                origin: key, host: host, in: webView?.window, scope: scope
            )
            askingOrigins.remove(key)

            guard allowed else {
                deliverError(id: id, to: frame, code: 1, message: "User denied Geolocation")
                return
            }
            start(Pending(id: id, frame: frame, highAccuracy: highAccuracy), watching: kind == "watch")
        }
    }

    // MARK: - 門番への問い合わせ

    // この枠は現在地を訊いてよいか。
    //
    // 判定できなかった時は全て断る。門番が注入されていない、
    // 不透明なオリジンだった、例外が飛んだ——理由は問わない。
    // 位置情報は漏れたら取り返しがつかないので、迷ったら断る側に倒す
    private func isAllowed(in frame: WKFrameInfo) async -> Bool {
        guard let webView else { return false }

        // 先にヘッダ。要求元の文書と最上位の文書、どちらかが自分を禁じていれば断る。
        // 連鎖の途中の文書のヘッダは見ていない（門番の各段で native に訊く口が要る。別件）
        guard headerAllows(documentURL: frame.request.url),
              headerAllows(documentURL: webView.url)
        else { return false }

        do {
            let result = try await webView.callAsyncJavaScript(
                GeolocationGuard.checkExpression,
                arguments: [:],
                in: frame,
                contentWorld: GeolocationGuard.world
            )
            return (result as? Bool) == true
        } catch {
            return false
        }
    }

    // MARK: - CoreLocation を回す

    private func start(_ request: Pending, watching: Bool) {
        // 精度は依頼のうち一番高いものに合わせる。
        // 一つの CLLocationManager を皆で使い回すので、
        // 後から来た緩い依頼で先の依頼の精度を落とさない
        if request.highAccuracy {
            manager.desiredAccuracy = kCLLocationAccuracyBest
        } else if manager.desiredAccuracy != kCLLocationAccuracyBest {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }

        if watching { watches.append(request) } else { oneShots.append(request) }

        switch manager.authorizationStatus {
        case .notDetermined:
            // ここで初めて macOS の許可を求める。
            // 答えは locationManagerDidChangeAuthorization に返ってくる
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            failAll(code: 1, message: "Location access is turned off for Skyscraper.")
        default:
            beginUpdates(watching: watching)
        }
    }

    // 名前が beginUpdates なのは、上の start(_ request:) の引数名と
    // ぶつかるからだ。引数の方が勝つので request() と書けない
    private func beginUpdates(watching: Bool) {
        if watching || !watches.isEmpty {
            manager.startUpdatingLocation()
        } else {
            // 一発取りはこれで済む。届いた時点で自分から止まる
            manager.requestLocation()
        }
    }

    private func stopIfIdle() {
        if watches.isEmpty { manager.stopUpdatingLocation() }
    }

    // MARK: - 返す

    private func deliver(_ location: CLLocation) {
        let coords = """
        {"coords":{"latitude":\(location.coordinate.latitude),\
        "longitude":\(location.coordinate.longitude),\
        "accuracy":\(max(location.horizontalAccuracy, 0)),\
        "altitude":\(location.verticalAccuracy >= 0 ? String(location.altitude) : "null"),\
        "altitudeAccuracy":\(location.verticalAccuracy >= 0 ? String(location.verticalAccuracy) : "null"),\
        "heading":\(location.course >= 0 ? String(location.course) : "null"),\
        "speed":\(location.speed >= 0 ? String(location.speed) : "null")},\
        "timestamp":\(Int(location.timestamp.timeIntervalSince1970 * 1000))}
        """

        let waiting = oneShots
        oneShots.removeAll()
        for request in waiting { push(id: request.id, to: request.frame, payload: coords, ok: true) }
        for request in watches { push(id: request.id, to: request.frame, payload: coords, ok: true) }

        stopIfIdle()
    }

    private func failAll(code: Int, message: String) {
        let waiting = oneShots + watches
        oneShots.removeAll()
        watches.removeAll()
        for request in waiting {
            deliverError(id: request.id, to: request.frame, code: code, message: message)
        }
        manager.stopUpdatingLocation()
    }

    private func deliverError(id: Int, to frame: WKFrameInfo, code: Int, message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        push(id: id, to: frame, payload: "{\"code\":\(code),\"message\":\"\(escaped)\"}", ok: false)
    }

    // permissions.query の答え。state は granted / denied / prompt のどれか
    private func pushQuery(id: Int, to frame: WKFrameInfo, state: String) {
        guard let webView else { return }
        let js = "window.__skyGeo && window.__skyGeo.deliverQuery(\(id), \"\(state)\");"
        webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
    }

    // ページ側の受け口へ押し返す。
    //
    // 届け先のフレームを明示するのが要点だ。省くと主フレームへ飛ぶ。
    // 世界も .page を指す——ポリフィルはそこに住んでいる
    private func push(id: Int, to frame: WKFrameInfo, payload: String, ok: Bool) {
        guard let webView else { return }
        let js = "window.__skyGeo && window.__skyGeo.deliver(\(id), \(ok ? "true" : "false"), \(payload));"
        webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
    }

    // MARK: - 畳む

    // タブを移送する時と捨てる時に呼ぶ。
    //
    // ContentView は removeAllScriptMessageHandlers() で受け口を剥がすが、
    // こちらが待たせている依頼はそれでは消えない。
    // 剥がした後にコールバックを撃つと、宛先の居ない所へ投げることになる
    func teardown() {
        manager.stopUpdatingLocation()
        oneShots.removeAll()
        watches.removeAll()
        askingOrigins.removeAll()
        headerPolicies.removeAll()
        webView = nil
    }
}

// MARK: - CoreLocation からの返事

// CLLocationManager を作った場（＝メイン）へ返ってくるので、
// assumeIsolated で受けられる。Task で包むと順番が入れ替わる
extension GeolocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated { deliver(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // kCLErrorDenied は OS 側で切られた時。それ以外は取得の失敗
            let denied = (error as? CLError)?.code == .denied
            failAll(code: denied ? 1 : 2,
                    message: denied
                        ? "Location access is turned off for Skyscraper."
                        : "Could not determine your location.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .notDetermined:
                break
            case .denied, .restricted:
                failAll(code: 1, message: "Location access is turned off for Skyscraper.")
            default:
                guard !oneShots.isEmpty || !watches.isEmpty else { return }
                beginUpdates(watching: !watches.isEmpty)
            }
        }
    }
}

// MARK: - 門番からの問い（隔離ワールド、返信付き）

// 門番が子の問い合わせに答える時、自分の文書のヘッダが子のオリジンを許しているかをここに訊く。
//
// この口は門番ワールドにしか登録しないので、ページ側の JS からは叩けない。
// どの文書からの問いかは frameInfo から分かるので、門番に自分の URL を名乗らせない——
// 送ってくるのは子のオリジンだけで、それは門番が event.origin から取った値だ
extension GeolocationProvider: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let childOrigin = body["origin"] as? String
        else { return (false, nil) }
        let allowed = headerAllowsDelegation(from: message.frameInfo.request.url, to: childOrigin)
        return (allowed, nil)
    }
}

// MARK: - 門番（隔離ワールド）

// その枠が現在地を訊いてよいかを見る係。
//
// ── なぜ専用の世界に置くのか ──
// ポリフィルは navigator.geolocation を差し替える都合上、
// ページ本来の世界（.page）に居る。つまりページ側の JS から
// window.webkit.messageHandlers を直接叩ける——ポリフィルを無視して
// native へ要求を投げられる。
//
// だから判定をポリフィル側に置いてはいけない。門番ごと跨がれる。
// 隔離ワールドは DOM をページと共有するが JS のグローバルが別物なので、
// ページ側から関数を差し替えられない。PasswordFill と同じ手だ。
//
// ── 答えは native が直接受け取る ──
// callAsyncJavaScript でこの世界に入り、戻り値をそのまま受ける。
// ページ側の JS を一度も経由しないのが要点だ
enum GeolocationGuard {

    // 専用の世界。名前付きの world は同じ名なら同じ実体が返るので、
    // 注入する側と叩く側でここを参照しておけば必ず揃う
    static let world = WKContentWorld.world(name: "SkyscraperGeolocationGuard")

    // 門番が native に訊く口の名前。この世界にしか登録しない
    static let messageHandlerName = "skyscraperGeolocationGuard"

    // 全フレームに仕込む。枠の中に居ないと門番にならない
    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: world
    )

    // native から叩く式。戻り値が true の時だけ通す
    static let checkExpression = "return await window.__skyGeoGuard.check();"

    private static let source = """
    (() => {
        if (window.__skyGeoGuard) { return; }

        // 答えを待っている問い合わせ。nonce → {resolve, timer}
        const pendingAsks = new Map();
        // 一度出た答えは覚える。
        // getCurrentPosition と watchPosition を同時に叩くサイトがあるので、
        // そのたびに祖先を辿るのは無駄だ。
        // ここはページ側から触れない世界なので、汚染される心配は無い
        let selfVerdict = null;

        const TIMEOUT_MS = 1500;

        const newNonce = () => {
            const a = new Uint32Array(4);
            crypto.getRandomValues(a);
            return Array.from(a, n => n.toString(16)).join('-');
        };

        // ──── allow 属性の解釈 ────

        // "camera; geolocation 'self' https://a.example" の形から
        // geolocation の分だけを抜き出す。書かれていなければ null。
        // null と空配列を分けるのは、省略時の既定値を
        // 適用するかどうかが違うからだ
        const geolocationAllowlist = (attr) => {
            if (typeof attr !== 'string') { return null; }
            for (const clause of attr.split(';')) {
                const parts = clause.trim().split(/\\s+/).filter(Boolean);
                if (!parts.length) { continue; }
                if (parts[0].toLowerCase() !== 'geolocation') { continue; }
                // 機能名だけ（allow="geolocation"）は 'src' と同じ意味
                return parts.length === 1 ? ["'src'"] : parts.slice(1);
            }
            return null;
        };

        // URL からオリジンを抜く。解けなければ null
        const originOf = (url, base) => {
            try { return new URL(url, base).origin; } catch (e) { return null; }
        };

        // この iframe の allow が childOrigin を許しているか。
        // 基準になるのはこの文書（親）のオリジンだ
        const allowsChild = (iframe, childOrigin) => {
            const list = geolocationAllowlist(iframe.getAttribute('allow'));
            // 書いてなければ既定値。geolocation の既定は 'self' ——
            // つまり同一オリジンの枠だけが通る
            if (list === null) { return childOrigin === window.location.origin; }

            for (const raw of list) {
                const token = raw.trim();
                if (token === '*') { return true; }
                if (token === "'none'") { return false; }
                if (token === "'self'") {
                    if (childOrigin === window.location.origin) { return true; }
                    continue;
                }
                if (token === "'src'") {
                    // src が無い枠（srcdoc / about:blank）は親のオリジンを継ぐ
                    const src = iframe.getAttribute('src');
                    const target = src
                        ? originOf(src, window.location.href)
                        : window.location.origin;
                    if (target && childOrigin === target) { return true; }
                    continue;
                }
                // クオート付きの未知の印は触らない（将来の拡張）
                if (token.startsWith("'")) { continue; }
                const listed = originOf(token);
                if (listed && childOrigin === listed) { return true; }
            }
            return false;
        };

        // ──── 自分の文書のヘッダ ────

        // 自分の文書が Permissions-Policy ヘッダで、このオリジンの子へ委ねることを許しているか。
        // ヘッダは JS から読めないので native に訊く。この口はこの世界にしか無い。
        // 届かなければ断る
        const headerPermits = async (childOrigin) => {
            try {
                const reply = await window.webkit.messageHandlers.skyscraperGeolocationGuard
                    .postMessage({ origin: childOrigin });
                return reply === true;
            } catch (e) {
                return false;
            }
        };

        // ──── 親への問い合わせ ────

        const askParent = () => new Promise((resolve) => {
            const nonce = newNonce();
            const timer = setTimeout(() => {
                pendingAsks.delete(nonce);
                resolve(false);   // 返ってこないのは何かがおかしい時だ
            }, TIMEOUT_MS);
            pendingAsks.set(nonce, { resolve: resolve, timer: timer });
            // targetOrigin を '*' にするのは、親のオリジンを
            // こちらから知る手立てが無いからだ。
            // 送るのは乱数だけなので、見られても失うものが無い
            parent.postMessage({ __skyGeoGuard: 'ask', nonce: nonce }, '*');
        });

        // ──── 受け付け ────

        window.addEventListener('message', async (event) => {
            const data = event.data;
            if (!data || typeof data !== 'object') { return; }

            if (data.__skyGeoGuard === 'ask') {
                // 子からの問い合わせ。
                //
                // event.source を自分の iframe の contentWindow と突き合わせて
                // どの枠かを特定する。この参照は WebKit が入れる実体なので、
                // 子が「自分は別の枠だ」と名乗ることはできない。
                // event.origin も同じ——子が自分のオリジンを偽れない
                let frame = null;
                for (const el of document.querySelectorAll('iframe, frame')) {
                    if (el.contentWindow === event.source) { frame = el; break; }
                }

                let allowed = false;
                if (frame) {
                    // 不透明なオリジン（sandbox で allow-same-origin 無し）は
                    // event.origin が "null" という文字列で届く。照合しようが無いので断る
                    if (event.origin && event.origin !== 'null'
                        && allowsChild(frame, event.origin)
                        && await headerPermits(event.origin)) {
                        // allow 属性も自分のヘッダも通している。
                        // だが自分自身が許可されていなければ、奥も通せない
                        allowed = await check();
                    }
                }

                if (event.source) {
                    event.source.postMessage({
                        __skyGeoGuard: 'answer', nonce: data.nonce, allowed: allowed
                    }, '*');
                }
                return;
            }

            if (data.__skyGeoGuard === 'answer') {
                // 親からの答え。nonce が合うものだけ受け取る。
                // 横から偽の答えを撃ち込まれても、乱数を当てられない
                const entry = pendingAsks.get(data.nonce);
                if (!entry) { return; }
                if (event.source !== parent) { return; }
                pendingAsks.delete(data.nonce);
                clearTimeout(entry.timer);
                entry.resolve(data.allowed === true);
            }
        });

        // ──── 本体 ────

        const check = async () => {
            if (selfVerdict !== null) { return selfVerdict; }

            // 最上位には親が居ない。
            // Permissions Policy の既定値（self）で自分自身は許可される。
            //
            // なお、サーバが Permissions-Policy ヘッダで
            // 自分を無効化している場合は見ていない——
            // ヘッダを拾うには native 側で応答を受けて
            // フレームごとに持ち回る仕組みが要る。別件だ
            if (window.top === window) {
                selfVerdict = true;
                return true;
            }

            selfVerdict = await askParent();
            return selfVerdict;
        };

        window.__skyGeoGuard = { check: check };
    })();
    """
}

// MARK: - ページ側のポリフィル

extension GeolocationProvider {

    // ページ本来の世界に、全フレームへ仕込む。
    //
    // 枠の中にも開けるのは、別の世界に門番（GeolocationGuard）を
    // 置いて allow 属性を見るようにしたからだ。
    // 判定をこちら側（.page）に置いてはいけない——
    // ページ側の JS から messageHandlers を直接叩けるので、
    // ここに門番を置いても門番ごと跨がれる
    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let source = """
    (() => {
        if (window.__skyGeo) { return; }

        let nextId = 1;
        const waiting = new Map();   // id → {success, error, timer, watch}
        let cached = null;           // 直近の現在地（maximumAge 用）

        const makeError = (code, message) => ({
            code: code, message: message,
            PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3
        });

        const post = (kind, id, options) => {
            window.webkit?.messageHandlers?.skyscraperGeolocation?.postMessage({
                kind: kind, id: id,
                highAccuracy: !!(options && options.enableHighAccuracy)
            });
        };

        // native から押し返された結果を配る
        const deliver = (id, ok, payload) => {
            const entry = waiting.get(id);
            if (!entry) { return; }
            if (entry.timer) { clearTimeout(entry.timer); entry.timer = null; }
            if (!entry.watch) { waiting.delete(id); }

            if (ok) {
                cached = payload;
                if (entry.success) { entry.success(payload); }
            } else if (entry.error) {
                entry.error(makeError(payload.code, payload.message));
            }
        };

        // permissions.query の答えを待っている係り。id → resolve
        const queries = new Map();

        const deliverQuery = (id, state) => {
            const resolve = queries.get(id);
            if (!resolve) { return; }
            queries.delete(id);
            resolve(state);
        };

        Object.defineProperty(window, '__skyGeo', {
            value: { deliver: deliver, deliverQuery: deliverQuery }, enumerable: false, configurable: true
        });

        // 期限は呼び出し側の都合なので、こちら側で数える。
        // native へ持ち込むと依頼ごとに別の時計を回すことになる
        const arm = (id, options) => {
            const ms = options && typeof options.timeout === 'number' ? options.timeout : Infinity;
            if (!isFinite(ms)) { return null; }
            return setTimeout(() => {
                const entry = waiting.get(id);
                if (!entry) { return; }
                if (!entry.watch) { waiting.delete(id); }
                if (entry.error) { entry.error(makeError(3, 'Timeout expired')); }
            }, Math.max(ms, 0));
        };

        // 手持ちの現在地で足りるか（maximumAge）。
        // 既定は 0 ＝毎回取り直す
        const freshEnough = (options) => {
            if (!cached) { return false; }
            const max = options && typeof options.maximumAge === 'number' ? options.maximumAge : 0;
            if (max <= 0) { return false; }
            return (Date.now() - cached.timestamp) <= max;
        };

        const geolocation = {
            getCurrentPosition(success, error, options) {
                if (freshEnough(options)) {
                    if (success) { setTimeout(() => success(cached), 0); }
                    return;
                }
                const id = nextId++;
                waiting.set(id, { success: success, error: error, watch: false, timer: null });
                waiting.get(id).timer = arm(id, options);
                post('get', id, options);
            },

            watchPosition(success, error, options) {
                const id = nextId++;
                waiting.set(id, { success: success, error: error, watch: true, timer: null });
                waiting.get(id).timer = arm(id, options);
                post('watch', id, options);
                return id;
            },

            clearWatch(id) {
                const entry = waiting.get(id);
                if (entry && entry.timer) { clearTimeout(entry.timer); }
                waiting.delete(id);
                post('clear', id, null);
            }
        };

        // 素の navigator.geolocation は Navigator.prototype 側の getter なので、
        // インスタンスに自前の項目を置けば影になる。
        // configurable を残すのは、後から剥がせないと直しようが無くなるからだ
        Object.defineProperty(navigator, 'geolocation', {
            value: Object.freeze(geolocation), enumerable: true, configurable: true
        });

        // ──── navigator.permissions.query ────
        //
        // サイトはこれで「訊く前に今どうか」を見る。素の WebKit は常に prompt を返すので、
        // 拒否済みでも「位置情報を許可してください」の案内が出続ける。
        // geolocation だけを横取りして、他は素通しにする
        const perms = navigator.permissions;
        if (perms && typeof perms.query === 'function') {
            const original = perms.query.bind(perms);

            // PermissionStatus らしい形。onchange は鳴らさない（変化の通知は未対応）
            const makeStatus = (state) => {
                const target = new EventTarget();
                Object.defineProperty(target, 'state', { value: state, enumerable: true });
                Object.defineProperty(target, 'name', { value: 'geolocation', enumerable: true });
                target.onchange = null;
                return target;
            };

            const query = (desc) => {
                if (!desc || desc.name !== 'geolocation') { return original(desc); }
                return new Promise((resolve) => {
                    const id = nextId++;
                    queries.set(id, (state) => resolve(makeStatus(state)));
                    post('query', id, null);
                });
            };

            Object.defineProperty(perms, 'query', { value: query, configurable: true, writable: true });
        }
    })();
    """
}
