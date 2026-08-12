//
//  PasswordStore.swift
//  Skyscraper
//
//  ログイン情報の保管庫。中身は macOS のキーチェーンに預ける。
//
//  自前のファイルに暗号化して置く道もあるが、鍵をどこに置くかで結局
//  キーチェーンに戻ってくる。それなら最初から OS の金庫を使う方がいい。
//  Keychain Access.app から中身を確かめられるし、こちらが消えても
//  利用者の資産として残る。
//
//  種別は kSecClassInternetPassword（Safari が使うのと同じ種別）。
//  サーバ名・利用者名・プロトコル・ポートが構造化された属性として入るので、
//  照合のたびに文字列を切り貼りしなくて済む。
//
//  他のアプリが預けた項目に触るとキーチェーンの許可ダイアログが出るので、
//  こちらの項目には kSecAttrSecurityDomain に印を付け、
//  読み書きは必ずその印で絞る。
//

import Combine
import Foundation

// MARK: - 預けた一件

struct SavedLogin: Identifiable, Hashable {
    let host: String
    let scheme: String   // "https" / "http"
    let port: Int
    let username: String
    let modified: Date?

    var id: String { "\(scheme)://\(host):\(port)|\(username)" }

    // 画面に出す名前。既定のポートは省く
    var origin: String {
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}

// MARK: - キーチェーンの出し入れ

@MainActor
final class PasswordStore: ObservableObject {
    static let shared = PasswordStore()

    // こちらが預けた項目の目印。読み書きは必ずこれで絞る
    private static let securityDomain = "Skyscraper"

    // 一覧の画面を起こすための合図。
    // 中身そのものは持たない（鍵はキーチェーンにあるので、
    // アプリ側に写しを抱えると消し忘れの元になる）
    @Published private(set) var revision = 0

    private init() {}

    // MARK: 照合の鍵

    // scheme と port を必ず埋めて、問い合わせの形を一定にする。
    // 片方だけ入れたり抜いたりすると、保存した時と探す時で鍵が食い違う
    static func defaultPort(for scheme: String) -> Int {
        scheme.lowercased() == "http" ? 80 : 443
    }

    private static func query(host: String, scheme: String, port: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrProtocol as String: scheme.lowercased() == "http"
                ? kSecAttrProtocolHTTP
                : kSecAttrProtocolHTTPS,
        ]
    }

    // MARK: 預ける

    @discardableResult
    func save(host: String, scheme: String, port: Int,
              username: String, password: String) -> Bool {
        guard !host.isEmpty, !password.isEmpty else { return false }

        var key = Self.query(host: host, scheme: scheme, port: port)
        key[kSecAttrAccount as String] = username

        let secret = Data(password.utf8)
        // 既にあれば中身だけ差し替える。
        // 消してから足すと、途中で失敗した時に元も失う
        let update: [String: Any] = [kSecValueData as String: secret]
        var status = SecItemUpdate(key as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = secret
            // Keychain Access.app の一覧で何者か分かるように
            item[kSecAttrLabel as String] = "\(host) (Skyscraper)"
            status = SecItemAdd(item as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            print("PasswordStore: save failed host=\(host) status=\(status)")
            return false
        }
        revision += 1
        return true
    }

    // MARK: 探す

    // その場所に預けてある利用者名の一覧。
    // 中身（パスワード）はここでは取り出さない——
    // 属性を読むだけならキーチェーンは何も訊いてこない
    func logins(host: String, scheme: String, port: Int) -> [SavedLogin] {
        var query = Self.query(host: host, scheme: scheme, port: port)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        return Self.fetch(query)
    }

    // 設定画面の一覧用。預けたもの全部
    func allLogins() -> [SavedLogin] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: Self.securityDomain,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        return Self.fetch(query).sorted {
            ($0.host, $0.username) < ($1.host, $1.username)
        }
    }

    private static func fetch(_ query: [String: Any]) -> [SavedLogin] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                print("PasswordStore: lookup failed status=\(status)")
            }
            return []
        }
        return items.compactMap(login(from:))
    }

    private static func login(from attributes: [String: Any]) -> SavedLogin? {
        guard let host = attributes[kSecAttrServer as String] as? String,
              let username = attributes[kSecAttrAccount as String] as? String
        else { return nil }

        let proto = attributes[kSecAttrProtocol as String] as? String
        let scheme = (proto == (kSecAttrProtocolHTTP as String)) ? "http" : "https"
        let port = attributes[kSecAttrPort as String] as? Int ?? defaultPort(for: scheme)

        return SavedLogin(host: host,
                          scheme: scheme,
                          port: port,
                          username: username,
                          modified: attributes[kSecAttrModificationDate as String] as? Date)
    }

    // MARK: 中身を取り出す

    // ここだけはキーチェーンが本物の鍵を渡す。
    // 記入する時と、設定画面で本人確認を経て見せる時にしか呼ばない
    func password(for login: SavedLogin) -> String? {
        var query = Self.query(host: login.host, scheme: login.scheme, port: login.port)
        query[kSecAttrAccount as String] = login.username
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                print("PasswordStore: read failed status=\(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 捨てる

    @discardableResult
    func delete(_ login: SavedLogin) -> Bool {
        var query = Self.query(host: login.host, scheme: login.scheme, port: login.port)
        query[kSecAttrAccount as String] = login.username
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            print("PasswordStore: delete failed status=\(status)")
            return false
        }
        revision += 1
        return true
    }

    // 設定画面の「すべて削除」。
    // キーチェーン全体ではなく、こちらが預けた印の付いた項目だけを消す
    @discardableResult
    func deleteAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: Self.securityDomain,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            print("PasswordStore: deleteAll failed status=\(status)")
            return false
        }
        revision += 1
        return true
    }
}

// MARK: - 「このサイトでは訊かない」の控え

@MainActor
final class PasswordNeverList {
    static let shared = PasswordNeverList()

    private let storageKey = "skyscraper.passwordNeverSave.v1"
    private var hosts: Set<String>

    private init() {
        hosts = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    var isEmpty: Bool { hosts.isEmpty }

    func contains(_ host: String) -> Bool {
        !host.isEmpty && hosts.contains(host)
    }

    func add(_ host: String) {
        guard !host.isEmpty else { return }
        hosts.insert(host)
        UserDefaults.standard.set(Array(hosts), forKey: storageKey)
    }

    func reset() {
        hosts.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
