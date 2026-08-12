//
//  PageError.swift
//  Skyscraper
//
//  読み込みに失敗した時に出す顛末書。
//
//  WKWebView は失敗しても何も描かない。放っておくと、繋がらないのか、
//  打ち間違えたのか、証明書で止められたのかが一切分からないまま
//  白紙が残る（新規タブから開いた場合は本当に真っ白になる）。
//

import Foundation
import SwiftUI

// MARK: - 失敗の中身

struct PageError {
    enum Kind {
        case offline            // こちらが繋がっていない
        case hostNotFound       // 名前を引けない
        case cannotConnect      // 相手に届かない・断られた
        case timedOut           // 返事が来ない
        case insecureConnection // TLS で止まった
        case badAddress         // そもそも開けない綴り
        case fileMissing        // file:// の行き先が無い
        case tooManyRedirects   // 回され続けた
        case other              // 上のどれでもない
    }

    let kind: Kind
    // 開こうとしていた場所。やり直しの宛先にもなる
    let url: URL?
    // WebKit が返した原文。分類が当たっていない時でも
    // 手がかりが残るように、小さく添えて出す
    let reason: String

    // MARK: 組み立て

    // 失敗の知らせを顛末書に変える。
    // 見せるほどのことではない失敗は nil を返す
    static func make(from error: Error, fallback: URL?) -> PageError? {
        let error = error as NSError
        guard !isRoutine(error) else { return nil }

        let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))

        return PageError(kind: kind(for: error),
                         url: failing ?? fallback,
                         reason: error.localizedDescription)
    }

    // 利用者にとっては失敗ではないもの。
    // これを弾かないと、ダウンロードを始めるたび、外部アプリへ引き渡すたび、
    // 読み込み中に別のリンクを踏むたびに顛末書が出る
    private static func isRoutine(_ error: NSError) -> Bool {
        switch error.domain {
        case NSURLErrorDomain:
            // 読み込みが取り消された。停止ボタン、次の読み込みの開始、
            // リダイレクトの競合など、日常的に起きる
            return error.code == NSURLErrorCancelled
        case "WebKitErrorDomain":
            // 公開の定数が無いので数値で見る。
            // 102: frame load interrupted by policy change——
            //      decidePolicyFor で .cancel / .download を返すと必ず来る
            //      （外部スキームの引き渡し、⌘クリック、ダウンロード化）
            // 204: 読み込みを WebKit の外側が引き取った
            return error.code == 102 || error.code == 204
        default:
            return false
        }
    }

    private static func kind(for error: NSError) -> Kind {
        guard error.domain == NSURLErrorDomain else { return .other }
        switch error.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return .offline
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .hostNotFound
        case NSURLErrorCannotConnectToHost,
             NSURLErrorResourceUnavailable,
             NSURLErrorCannotLoadFromNetwork:
            return .cannotConnect
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .insecureConnection
        case NSURLErrorUnsupportedURL,
             NSURLErrorBadURL:
            return .badAddress
        case NSURLErrorFileDoesNotExist,
             NSURLErrorFileIsDirectory,
             NSURLErrorNoPermissionsToReadFile:
            return .fileMissing
        case NSURLErrorHTTPTooManyRedirects,
             NSURLErrorRedirectToNonExistentLocation:
            return .tooManyRedirects
        default:
            return .other
        }
    }

    // MARK: 見せ方

    var symbol: String {
        switch kind {
        case .offline:            return "bolt.horizontal"
        case .hostNotFound:       return "questionmark.circle"
        case .cannotConnect:      return "xmark.circle"
        case .timedOut:           return "hourglass"
        case .insecureConnection: return "lock.trianglebadge.exclamationmark"
        case .badAddress:         return "exclamationmark.triangle"
        case .fileMissing:        return "doc.questionmark"
        case .tooManyRedirects:   return "arrow.triangle.2.circlepath"
        case .other:              return "exclamationmark.triangle"
        }
    }

    var headline: String {
        switch kind {
        case .offline:
            return String(localized: "You are not connected")
        case .hostNotFound:
            return String(localized: "Server not found")
        case .cannotConnect:
            return String(localized: "Cannot reach the server")
        case .timedOut:
            return String(localized: "The server did not answer")
        case .insecureConnection:
            return String(localized: "Cannot connect securely")
        case .badAddress:
            return String(localized: "This address cannot be opened")
        case .fileMissing:
            return String(localized: "File not found")
        case .tooManyRedirects:
            return String(localized: "The site keeps redirecting")
        case .other:
            return String(localized: "The page could not be opened")
        }
    }

    var advice: String {
        switch kind {
        case .offline:
            return String(localized: "Check the network connection, then try again.")
        case .hostNotFound:
            return String(localized: "The address may be misspelled, or the site may no longer exist.")
        case .cannotConnect:
            return String(localized: "The server refused the connection. It may be down, or the port may be wrong.")
        case .timedOut:
            return String(localized: "The server took too long. It may be busy.")
        case .insecureConnection:
            return String(localized: "The certificate could not be verified. Skyscraper offers no way past this, because there is no safe way to tell a misconfigured site from an intercepted one.")
        case .badAddress:
            return String(localized: "Skyscraper cannot open an address of this kind.")
        case .fileMissing:
            return String(localized: "The file may have been moved or deleted.")
        case .tooManyRedirects:
            return String(localized: "The site sent Skyscraper back and forth too many times.")
        case .other:
            return String(localized: "Try again. If it keeps happening, the site is likely at fault.")
        }
    }
}

// MARK: - 顛末書のページ

// ロビー（新規タブページ）と同じ黒地・金線の造りにする。
// 失敗した時だけ別の様式になると、それ自体が驚きになる
struct ErrorPage: View {
    let error: PageError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: error.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Deco.dimGold)
                .padding(.bottom, 20)

            Text(verbatim: error.headline)
                .font(.system(size: 15, design: .serif))
                .tracking(3)
                .foregroundColor(Deco.cream)
                .multilineTextAlignment(.center)

            Zigzag(teeth: 8)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(width: 120, height: 6)
                .padding(.vertical, 16)

            // どこへ行こうとして失敗したのか。
            // WebKit はアドレスを巻き戻すので、ここに出さないと分からなくなる
            if let url = error.url {
                Text(verbatim: url.absoluteString)
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(Deco.gold)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
                    .padding(.bottom, 14)
            }

            Text(verbatim: error.advice)
                .font(.system(size: 12, design: .serif))
                .foregroundColor(Deco.dimGold)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)

            Button(action: onRetry) {
                Text("Try Again")
                    .font(.system(size: 12, design: .serif))
                    .tracking(2)
                    .foregroundColor(Deco.gold)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .overlay(Hexagon(inset: 7).stroke(Deco.faintGold, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 26)

            // WebKit の原文。分類が外れていても、ここを見れば追える
            Text(verbatim: error.reason)
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.faintGold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
                .padding(.top, 22)

            Spacer()

            LobbyBottomFan()
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Deco.ink)
        .overlay { LobbyFrame() }
    }
}
