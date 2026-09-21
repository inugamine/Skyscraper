//
//  PasswordExport.swift
//  Skyscraper
//
//  預かったログイン情報を他所へ渡す。PasswordImport.swift の裏返し。
//
//  形式は Chrome の書き出しと同じ name,url,username,password,note。
//  Firefox・Safari・Passwords.app・Edge、それに大抵のパスワード管理ソフトが
//  この列名を読める。事実上の共通語なので、これに合わせる。
//
//  中身は一件ずつ PasswordStore.password(for:) で取り出す。
//  全件の中身を一度の問い合わせで取る道 (kSecMatchLimitAll と
//  kSecReturnData の組み合わせ) は、macOS の旧来のキーチェーンでは
//  errSecParam で弾かれるので使わない。
//

//  このファイルは表計算ソフトで開く物ではなく、他所のブラウザに読ませる物なので、
//  CSV インジェクション (= や + で始まる欄が表計算ソフトで式になる件) には手を打たない。
//  (頭に ' を足すと、取り込んだ先でパスワードそのものが変わってしまうため)
//
//  列名の英語は String(localized:) で包まない。人へ見せる文言ではなく、
//  読み手のブラウザが照合する札だから。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum PasswordExport {

    struct Result {
        let exported: Int
        // キーチェーンが中身を返さなかった件数
        let skipped: Int
    }

    // MARK: - 組み立て

    // 盤を出さずに中身だけ組む。試すのもここを呼べばいい
    @MainActor
    static func csv(from logins: [SavedLogin]) -> (text: String, result: Result) {
        var lines = [row(["name", "url", "username", "password", "note"])]
        var skipped = 0

        for login in logins {
            guard let password = PasswordStore.shared.password(for: login) else {
                skipped += 1
                continue
            }
            // Chrome は url に末尾の / まで付けて書く。読み手はどちらでも受けるが、
            // 倣っておけば Chrome の書き出しと見比べた時に差が出ない
            lines.append(row([
                login.host,
                login.origin + "/",
                login.username,
                password,
                "",
            ]))
        }

        // 行の区切りは RFC 4180 通りの CRLF。
        // こちらの取り込み (CSV.rows) は LF も CRLF も受ける
        let text = lines.joined(separator: "\r\n") + "\r\n"
        return (text, Result(exported: logins.count - skipped, skipped: skipped))
    }

    // 全ての欄を二重引用符で括る。
    // 括る要る要らないを欄ごとに判定するより、常に括る方が取りこぼしが無い。
    // パスワードには何が入っているか分からない
    private static func row(_ fields: [String]) -> String {
        fields
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: ",")
    }

    // MARK: - 書き込み

    // 本人確認は呼び元 (PasswordListView) が済ませてから来る。
    // ここは置き場所を選ばせて書くだけ。取り消されたら nil
    @MainActor
    static func chooseFileAndWrite(_ logins: [SavedLogin]) throws -> (file: URL, result: Result)? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName()
        panel.message = String(localized: "Choose where to save the passwords file.")
        panel.prompt = String(localized: "Export")

        guard panel.runModal() == .OK, let file = panel.url else { return nil }

        let (text, result) = csv(from: logins)
        try write(Data(text.utf8), to: file)
        return (file, result)
    }

    // 権限は 0600 (本人だけが読み書きできる) で作る。
    // 書いてから権限を絞ると、その間だけ他の利用者から読める隙ができる。
    // 作る時に渡しておけば隙は無い
    private static func write(_ data: Data, to file: URL) throws {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]

        guard manager.createFile(atPath: file.path, contents: data, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // 既にあったファイルを上書きした場合、元の権限が残ることがある。念のため締め直す
        try manager.setAttributes(attributes, ofItemAtPath: file.path)
    }

    // 名前に日付を入れる (BookmarkExport と同じ理由)。
    // en_US_POSIX に固定するのは和暦が綴りへ混ざるのを防ぐため
    private static func suggestedName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Skyscraper Passwords \(formatter.string(from: Date())).csv"
    }
}
