//
//  CertificateTrust.swift
//  Skyscraper
//
//  サーバ証明書が検証を通らなかった時、その先へ進むための細い道。
//
//  WKWebView は didReceive challenge を実装しない限り、証明書で転んだ接続を
//  そのまま捨てる。自己署名の証明書を立てたローカルの開発サーバは、それだけで
//  永久に開けない（顛末書が出て終わり）。手元の Raspberry Pi に繋ぐたびに
//  別のブラウザを開く羽目になるのは、道具として不便だ。
//
//  とはいえ「検証を素通しする道」を常設するのは論外なので、条件を絞る。
//  ・利用者が証明書の中身を見た上で、自分で押した時だけ
//  ・その場所（ホストとポート）に限って
//  ・アプリを終うまでの間だけ
//  ディスクには何も書かない——次の起動では、また同じ問いから始まる。
//  「一度通したら以後ずっと」は、間に誰かが割り込んでいた場合に
//  取り返しがつかなくなる。
//

import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - 証明書一枚ぶんの読み下し

struct CertificateSummary {
    let host: String
    let subject: String        // 発行先（CN か、それに準ずる要約）
    let issuer: String         // 発行者の CN
    let notBefore: Date?
    let notAfter: Date?
    let fingerprint: String    // SHA-256（16 進・空白区切り）
    // 検証が何で転んだか。Security framework の言い分をそのまま出す
    let problem: String

    // 自分で自分に署名している＝どこの認証局も裏書きしていない。
    // ローカルの開発サーバはほぼこれだ
    var isSelfSigned: Bool { !subject.isEmpty && subject == issuer }

    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    var isNotYetValid: Bool {
        guard let notBefore else { return false }
        return notBefore > Date()
    }

    // ダイアログの本文。項目名を左に揃えて縦に並べる
    var detailText: String {
        var lines: [String] = []
        if !problem.isEmpty {
            lines.append(problem)
            lines.append("")
        }
        if !subject.isEmpty {
            lines.append(String(localized: "Issued to: \(subject)"))
        }
        if !issuer.isEmpty {
            lines.append(String(localized: "Issued by: \(issuer)"))
        }
        if let notBefore, let notAfter {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(String(localized: "Valid: \(formatter.string(from: notBefore)) – \(formatter.string(from: notAfter))"))
        }
        if !fingerprint.isEmpty {
            lines.append("")
            lines.append(String(localized: "SHA-256 fingerprint:"))
            lines.append(fingerprint)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 証明書を読む係

enum CertificateInspector {

    // SecTrust から先頭（サーバ本人）の証明書を読み下す。
    //
    // 検証をここで回し直すのは、転んだ理由を文章で受け取るためだ。
    // SecTrustEvaluateWithError は場合によっては通信に出る（OCSP 等）が、
    // ここへ来る時点で WebKit が既に一度評価しており、その答えは
    // 手元に残っている。押された後にしか呼ばないので、待たせても構わない
    static func summarize(trust: SecTrust?, host: String) -> CertificateSummary? {
        guard let trust else { return nil }

        var error: CFError?
        let passed = SecTrustEvaluateWithError(trust, &error)
        let problem = passed
            ? ""
            : (error.map { CFErrorCopyDescription($0) as String } ?? "")

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            return CertificateSummary(host: host, subject: "", issuer: "",
                                      notBefore: nil, notAfter: nil,
                                      fingerprint: "", problem: problem)
        }

        return CertificateSummary(
            host: host,
            subject: subject(of: leaf),
            issuer: issuer(of: leaf),
            notBefore: date(of: leaf, oid: kSecOIDX509V1ValidityNotBefore),
            notAfter: date(of: leaf, oid: kSecOIDX509V1ValidityNotAfter),
            fingerprint: fingerprint(of: leaf),
            problem: problem
        )
    }

    // MARK: 中身の取り出し

    private static func subject(of certificate: SecCertificate) -> String {
        // 要約は CN が入っていればそれ、無ければ組織名などに落ちる。
        // どう転んでも一行で読める形で返ってくるので、これで足りる
        (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
    }

    private static func issuer(of certificate: SecCertificate) -> String {
        commonName(in: property(of: certificate, oid: kSecOIDX509V1IssuerName))
    }

    // 識別名（DN）は項目の配列で返る。CN の一つを拾う。
    // 無ければ組織名（O）、それも無ければ最初の項目で代用する
    private static func commonName(in value: Any?) -> String {
        guard let parts = value as? [[String: Any]] else { return "" }

        func text(matching oid: CFString) -> String? {
            for part in parts
            where part[kSecPropertyKeyLabel as String] as? String == (oid as String) {
                if let text = part[kSecPropertyKeyValue as String] as? String, !text.isEmpty {
                    return text
                }
            }
            return nil
        }

        if let cn = text(matching: kSecOIDCommonName) { return cn }
        if let org = text(matching: kSecOIDOrganizationName) { return org }
        return parts.first?[kSecPropertyKeyValue as String] as? String ?? ""
    }

    private static func date(of certificate: SecCertificate, oid: CFString) -> Date? {
        // 値は CFAbsoluteTime（2001-01-01 を原点とする秒数）で入っている
        guard let number = property(of: certificate, oid: oid) as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    private static func property(of certificate: SecCertificate, oid: CFString) -> Any? {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil)
                as? [String: Any],
              let entry = values[oid as String] as? [String: Any]
        else { return nil }
        return entry[kSecPropertyKeyValue as String]
    }

    // SHA-256 の指紋。
    // 一目で見比べられるよう、二桁ずつ空けて三行に折る
    private static func fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        let bytes = Array(SHA256.hash(data: data))
        let groups = stride(from: 0, to: bytes.count, by: 12).map { start -> String in
            bytes[start..<min(start + 12, bytes.count)]
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
        }
        return groups.joined(separator: "\n")
    }
}

// MARK: - 例外の控え

@MainActor
final class CertificateExceptionStore {
    static let shared = CertificateExceptionStore()

    // "host:port"。UserDefaults にもキーチェーンにも書かない。
    // アプリを終えば消える——それがこの仕組みの肝だ
    private var allowed: Set<String> = []

    private init() {}

    var isEmpty: Bool { allowed.isEmpty }

    // 通した場所の一覧（設定画面の表示用）
    var places: [String] { allowed.sorted() }

    private static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    func isAllowed(host: String, port: Int) -> Bool {
        !host.isEmpty && allowed.contains(Self.key(host: host, port: port))
    }

    func allow(host: String, port: Int) {
        guard !host.isEmpty else { return }
        allowed.insert(Self.key(host: host, port: port))
    }

    func forget(host: String, port: Int) {
        allowed.remove(Self.key(host: host, port: port))
    }

    func reset() {
        allowed.removeAll()
    }

    // MARK: 押し切られるまでの手順

    // 証明書の中身を見せ、それでも進むかを訊く。
    // 既定のボタンは「戻る」だ。Return を叩いただけで例外が生まれてはいけない
    func confirm(host: String, trust: SecTrust?, in window: NSWindow?) async -> Bool {
        let summary = CertificateInspector.summarize(trust: trust, host: host)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Cannot verify the identity of “\(host)”")

        var lines: [String] = []
        if let summary {
            lines.append(summary.detailText)
        }
        lines.append("")
        lines.append(String(localized: "If you continue, Skyscraper will connect anyway and stop asking about this server until you quit. Do this only for a server you set up yourself."))
        alert.informativeText = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let back     = alert.addButton(withTitle: String(localized: "Go Back"))
        let proceed  = alert.addButton(withTitle: String(localized: "Continue Anyway"))
        back.keyEquivalent = "\r"
        proceed.keyEquivalent = ""
        // 進む方は既定の見た目から外して、押す気が要る形にする
        proceed.hasDestructiveAction = true

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }

        // 一番目が「戻る」なので、二番目を押された時だけ通す
        return response == .alertSecondButtonReturn
    }

    // 証明書をただ見せるだけ（サイト情報の「証明書を表示」）。
    // 何かを許すわけではないので、ボタンは閉じるだけ
    func show(host: String, trust: SecTrust?, in window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Certificate for “\(host)”")

        if let summary = CertificateInspector.summarize(trust: trust, host: host) {
            alert.informativeText = summary.detailText
        } else {
            alert.informativeText = String(localized: "Skyscraper does not have the certificate for this connection.")
        }
        alert.addButton(withTitle: String(localized: "OK"))

        if let window {
            _ = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            alert.runModal()
        }
    }
}
