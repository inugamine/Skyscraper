//
//  HTTPAuth.swift
//  Skyscraper
//
//  HTTP の認証チャレンジ（Basic / Digest / NTLM）を引き受ける係。
//
//  WKWebView は webView(_:didReceive:completionHandler:) を実装しない限り、
//  401 を返すサーバの前で立ち往生する。WebKit 自身は入力窓を持たないので、
//  資格情報を渡せないまま読み込みが終わり、白紙かサーバの素っ気ない
//  401 の本文が残る（何を求められているのかさえ分からない）。
//  ここで窓を出し、答えを WebKit へ返す。
//
//  預け先は既存の PasswordStore（キーチェーン）。フォームのログインと
//  同じ棚に載るので、設定画面の一覧からまとめて管理できる。
//  realm ごとの区別は付けていない——本来 realm は kSecAttrSecurityDomain に
//  入れる属性だが、そこは既に「Skyscraper が預けたもの」の印として
//  使っており、鍵の形を変えると今預けてあるものが一切引けなくなる。
//  同じホストで realm を使い分けるサーバは稀なので、場所（ホスト・
//  スキーム・ポート）単位で足りると判断した。
//

import AppKit
import Foundation

@MainActor
final class HTTPAuthPrompter {
    // 利用者の答え。呼び元が URLCredential に組み直して WebKit へ渡す
    struct Answer {
        let user: String
        let password: String
    }

    // 保存すると言われた中身。ただし打った時点ではまだ正しいか分からないので、
    // 読み込みが実るまで手元に置く（間違いをキーチェーンに焼き付けない）
    private struct PendingSave {
        let host: String
        let scheme: String
        let port: Int
        let user: String
        let password: String
    }

    // この器で通した資格情報（場所ごと）。
    // 同じページの画像や CSS にも一枚ずつチャレンジが飛んでくるので、
    // 一度答えたら以後は黙って使い回す
    private var accepted: [String: Answer] = [:]
    // 断った場所。次の読み込みが始まるまでは訊き直さない。
    // これが無いと、キャンセルした直後に同じ問いが連打される
    private var declined: Set<String> = []
    // 今まさに窓を出している場所と、その答えを待っている者たち。
    // 一枚のページから同時に何本もチャレンジが来ても、窓は一つで済ませる
    private var waiting: [String: [CheckedContinuation<Answer?, Never>]] = [:]
    // 実ったら預ける約束（場所ごと）
    private var pendingSaves: [String: PendingSave] = [:]

    // MARK: - 出入口

    // ここで扱える種類か。
    // サーバ証明書（ServerTrust）は別の係が受ける（CertificateTrust.swift）。
    // クライアント証明書は WebKit に任せる——
    // 選ばせる相手（キーチェーンの識別情報）が別の話になる
    static func canHandle(_ challenge: URLAuthenticationChallenge) -> Bool {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            return true
        default:
            return false
        }
    }

    // 新しい読み込みが始まった。断りの記憶は仕切り直す
    //（「もう一度」で訊き直せるようにするため）
    func noteNavigationStarted() {
        declined.removeAll()
    }

    // 中身が届いた＝直前に通した資格情報は撥ねられなかった。
    // 間違っていれば、この前に previousFailureCount 付きの
    // チャレンジが飛んできて約束は破棄されている
    func noteNavigationSucceeded() {
        guard !pendingSaves.isEmpty else { return }
        for save in pendingSaves.values {
            PasswordStore.shared.save(host: save.host,
                                      scheme: save.scheme,
                                      port: save.port,
                                      username: save.user,
                                      password: save.password)
        }
        pendingSaves.removeAll()
    }

    // MARK: - 本体

    // 資格情報を用意する。nil なら利用者が断ったということ
    func answer(for challenge: URLAuthenticationChallenge, in window: NSWindow?) async -> Answer? {
        let space = challenge.protectionSpace
        let key = Self.key(for: space)
        let scheme = (space.protocol ?? "https").lowercased() == "http" ? "http" : "https"
        let port = space.port == 0 ? PasswordStore.defaultPort(for: scheme) : space.port
        let failed = challenge.previousFailureCount > 0

        if failed {
            // 通したはずのものが撥ねられた。抱えている分は捨てて訊き直す
            accepted[key] = nil
            pendingSaves[key] = nil
        } else if let known = accepted[key] {
            return known
        }

        if declined.contains(key) { return nil }

        // 既に窓が出ているなら、その答えを分けてもらう
        if waiting[key] != nil {
            return await withCheckedContinuation { continuation in
                waiting[key]?.append(continuation)
            }
        }
        waiting[key] = []

        let saved = PasswordStore.shared.logins(host: space.host, scheme: scheme, port: port)
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }

        var answer: Answer?

        if !failed, saved.count == 1, let password = PasswordStore.shared.password(for: saved[0]) {
            // 預けてあるものが一件だけなら、黙って試す。
            // 撥ねられたら previousFailureCount が立ち、次はここを通らずに窓が出る
            answer = Answer(user: saved[0].username, password: password)
        } else if let asked = await ask(host: space.host,
                                        realm: space.realm ?? "",
                                        insecure: scheme == "http",
                                        failed: failed,
                                        defaultUser: saved.first?.username ?? "",
                                        offerSave: !PasswordNeverList.shared.contains(space.host),
                                        in: window) {
            answer = Answer(user: asked.user, password: asked.password)
            if asked.save {
                pendingSaves[key] = PendingSave(host: space.host, scheme: scheme, port: port,
                                                user: asked.user, password: asked.password)
            }
        }

        if let answer {
            accepted[key] = answer
        } else {
            declined.insert(key)
        }

        // 待たせていた者たちに同じ答えを配る
        let others = waiting.removeValue(forKey: key) ?? []
        for continuation in others { continuation.resume(returning: answer) }

        return answer
    }

    // MARK: - 問い合わせの窓

    private func ask(host: String,
                     realm: String,
                     insecure: Bool,
                     failed: Bool,
                     defaultUser: String,
                     offerSave: Bool,
                     in window: NSWindow?) async -> (user: String, password: String, save: Bool)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let site = host.isEmpty ? String(localized: "this site") : host
        alert.messageText = String(localized: "Sign in to “\(site)”")

        var lines: [String] = []
        if failed {
            lines.append(String(localized: "The user name or password was not accepted."))
        }
        let shown = Self.displayRealm(realm)
        if !shown.isEmpty {
            lines.append(String(localized: "The server says: “\(shown)”"))
        }
        if insecure {
            // http では資格情報がそのまま線の上を流れる。黙って通す話ではない
            lines.append(String(localized: "This connection is not encrypted. Your user name and password will be sent in the clear."))
        }
        alert.informativeText = lines.joined(separator: "\n")

        let signIn = alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        signIn.keyEquivalent = "\r"

        // 入力欄は自前で組んで載せる。NSAlert には既製の入力欄が無い
        let width: CGFloat = 320
        let fieldX: CGFloat = 98
        let fieldWidth = width - fieldX
        let passY: CGFloat = offerSave ? 34 : 4
        let userY: CGFloat = passY + 28

        let userField = NSTextField(frame: NSRect(x: fieldX, y: userY, width: fieldWidth, height: 24))
        userField.stringValue = defaultUser
        userField.placeholderString = String(localized: "User Name")

        let passField = NSSecureTextField(frame: NSRect(x: fieldX, y: passY, width: fieldWidth, height: 24))
        passField.placeholderString = String(localized: "Password")

        let saveBox = NSButton(checkboxWithTitle: String(localized: "Save this password"),
                               target: nil, action: nil)
        saveBox.frame = NSRect(x: fieldX, y: 4, width: fieldWidth, height: 18)
        saveBox.state = .on

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: offerSave ? 92 : 62))
        accessory.addSubview(Self.label(String(localized: "User Name:"), y: userY, width: fieldX - 8))
        accessory.addSubview(Self.label(String(localized: "Password:"), y: passY, width: fieldX - 8))
        accessory.addSubview(userField)
        accessory.addSubview(passField)
        if offerSave { accessory.addSubview(saveBox) }
        alert.accessoryView = accessory

        // タブ送りの輪。載せた後に繋がないと、AppKit が張り直して切れる
        userField.nextKeyView = passField
        passField.nextKeyView = offerSave ? saveBox : userField
        saveBox.nextKeyView = userField

        // 焦点は空いている方の欄へ。利用者名が既に入っているなら鍵の欄から始める。
        // layout() を先に呼ばないと、この時点ではまだ窓の中身が組まれていない
        alert.layout()
        alert.window.initialFirstResponder = defaultUser.isEmpty ? userField : passField

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }

        guard response == .alertFirstButtonReturn else { return nil }

        let user = userField.stringValue
        let password = passField.stringValue
        // 両方空のまま押された＝実質キャンセル。
        // 空の資格情報を送っても 401 が返るだけで、窓が出直すだけになる
        guard !user.isEmpty || !password.isEmpty else { return nil }

        return (user, password, offerSave && saveBox.state == .on && !password.isEmpty)
    }

    // MARK: - 小物

    private static func label(_ text: String, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        // 入力欄より少し下がった位置に置くと、文字の高さが揃って見える
        field.frame = NSRect(x: 0, y: y + 4, width: width, height: 17)
        return field
    }

    // realm はサーバが好きに書ける文字列だ。そのまま出すと、
    // 改行を混ぜて偽の説明文を継ぎ足すような真似ができる。
    // 一行に均して、長さも切っておく
    private static func displayRealm(_ realm: String) -> String {
        let flat = realm
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return "" }
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }

    private static func key(for space: URLProtectionSpace) -> String {
        let scheme = (space.protocol ?? "").lowercased()
        return "\(space.authenticationMethod)|\(scheme)://\(space.host):\(space.port)|\(space.realm ?? "")"
    }
}
