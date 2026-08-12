//
//  PasswordImport.swift
//  Skyscraper
//
//  他所で貯めたログイン情報を引き取る。
//
//  Passwords.app（iCloud キーチェーン）の中身は、第三者のアプリからは
//  読めない。login キーチェーンとは別の「データ保護キーチェーン」に入って
//  いて、アクセスグループとエンタイトルメントで囲われているからだ。
//  ASAuthorizationPasswordRequest はあの見慣れたシートを出せるが、
//  Associated Domains に宣言した自分のドメインにしか使えない。
//
//  つまり橋は無い。代わりに、書き出したものを引き取る口を用意する。
//  Passwords.app の「すべてのパスワードを書き出す…」が吐く CSV を土台に、
//  他のブラウザやパスワード管理ソフトの列名にも当たるようにしてある。
//

import Foundation
import UniformTypeIdentifiers

enum PasswordImport {

    struct Result {
        let imported: Int
        let skipped: Int
    }

    enum Failure: LocalizedError {
        case unreadable
        case noColumns

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "Could not read that file.")
            case .noColumns:
                return String(localized: "That file has no address, user name and password columns.")
            }
        }
    }

    // MARK: - 取り込み

    @MainActor
    static func run(from file: URL) throws -> Result {
        guard let text = read(file) else { throw Failure.unreadable }

        var rows = CSV.rows(text).filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        guard !rows.isEmpty else { throw Failure.noColumns }

        let header = rows.removeFirst()
        guard let urlColumn = column(header, ["url", "website", "websiteurl", "uri", "loginuri", "site"]),
              let passwordColumn = column(header, ["password", "pass", "loginpassword"])
        else { throw Failure.noColumns }
        // 利用者名の欄が無い書き出しもある（その場合は空のまま預かる）
        let userColumn = column(header, ["username", "user", "login", "loginusername", "account", "email"])

        var imported = 0
        var skipped = 0

        for row in rows {
            guard let password = value(row, passwordColumn),
                  !password.isEmpty,
                  let address = value(row, urlColumn),
                  let origin = origin(of: address)
            else {
                skipped += 1
                continue
            }
            let username = userColumn.flatMap { value(row, $0) } ?? ""

            // 同じ場所・同じ利用者名なら中身が差し替わる（PasswordStore.save の作り）
            if PasswordStore.shared.save(host: origin.host,
                                         scheme: origin.scheme,
                                         port: origin.port,
                                         username: username,
                                         password: password) {
                imported += 1
            } else {
                skipped += 1
            }
        }

        return Result(imported: imported, skipped: skipped)
    }

    // MARK: - 下ごしらえ

    private static func read(_ file: URL) -> String? {
        if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        // 書き出し元によっては UTF-16 や Shift_JIS で来る
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: file, usedEncoding: &encoding)
    }

    private static func value(_ row: [String], _ index: Int?) -> String? {
        guard let index, index < row.count else { return nil }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 列名の当て。書き出し元ごとに綴りが違うので、
    // 空白・下線・大文字小文字を均してから見比べる
    private static func column(_ header: [String], _ names: [String]) -> Int? {
        for (index, raw) in header.enumerated() {
            let key = raw
                .replacingOccurrences(of: "\u{FEFF}", with: "")  // BOM
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
            if names.contains(key) { return index }
        }
        return nil
    }

    // "https://github.com/login" も "github.com" も受ける
    private static func origin(of address: String) -> (host: String, scheme: String, port: Int)? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { return nil }

        let scheme = (components.scheme ?? "https").lowercased()
        // 預けられるのは web の出所だけ。ios: や android: の行は飛ばす
        guard scheme == "https" || scheme == "http" else { return nil }

        return (host, scheme, components.port ?? PasswordStore.defaultPort(for: scheme))
    }
}

// MARK: - CSV の読み取り

// RFC 4180。引用符の中に来るカンマ・改行・二重引用符に耐える。
// パスワードには何が入っているか分からないので、素朴な split では割れない
enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    // "" は引用符そのもの
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            // CRLF は Swift では一文字（拡張書記素クラスタ）として来る。
            // "\r" と "\n" だけを見ていると、Windows 生まれの CSV が
            // まるごと一行として読まれ、一件も取り込めない
            case "\r\n", "\r", "\n":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            default:
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
