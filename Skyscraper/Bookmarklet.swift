//
//  Bookmarklet.swift
//  Skyscraper
//
//  javascript: で始まるブックマーク——いわゆるブックマークレットを走らせる。
//
//  Instapaper や Pocket の「あとで読む」は、今見ているページの番地を
//  向こうへ渡す小さな JavaScript を、ブックマークの姿で配っている。
//
//      javascript:function iprl5(){var d=document, ... }iprl5();void(0)
//
//  これは行き先ではなく命令だ。load() に渡しても何も起きないので、
//  番地は書き換えず、今開いているページの上でそのまま走らせる。
//
//  ── 百分率の戻し ──
//
//  javascript: の中身は「URL に書かれた文字列」なので、走らせる前に
//  百分率符号化 (%27 など) を戻す決まりになっている。
//  Instapaper が配るものは引用符が %27 のまま入っているから、
//  戻さないと構文からして通らない。
//
//      ...?a=read-later&u=%27+encodeURIComponent(l.href)+%27
//                        ↓
//      ...?a=read-later&u='+encodeURIComponent(l.href)+'
//
//  String.removingPercentEncoding は、壊れた組み ("100% 確実" の % など) が
//  一つでも混じると全体を諦めて nil を返す。それでは巻き添えでまともな %27 まで戻らないので、自前で一組ずつ見て回る。
//  戻せない % は文字としてそのまま残す (URL 規格の percent-decode も同じ)。
//
//  ── 走らせる世界 ──
//
//  ページと同じ世界 (WKContentWorld.page) で走らせる。隔離された世界では
//  window も document も別物になり、ページの DOM を掴むというブックマークレットの用を成さない。
//
//  ── ここでは走らせないもの ──
//
//  アドレスバーに打ち込まれた javascript: は、今まで通り検索語に落とす
//  (Tab.interpret)。他所のブラウザが貼り付けからスキームを剥がすのと
//  同じ理由で、「この一行をアドレスバーに貼って」と唆す手口に
//  入口を開けないためだ。走らせるのは、利用者が自分の棚に
//  入れたブックマークだけに限る。
//

import Foundation
import WebKit
import os

enum Bookmarklet {

    static let scheme = "javascript:"

    private static let log = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                                    category: "Bookmarklet")

    // MARK: - 見分け

    // 綴りだけを見る。中身が空でも棚には並ぶので、
    // 「これはブックマークレットか」と「走らせられるか」は別の問い。
    static func isBookmarklet(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix(scheme)
    }

    // 走らせられる中身を取り出す。
    // ブックマークレットでない、または中身が空なら nil
    static func source(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(scheme) else { return nil }

        let body = decodePercent(String(text.dropFirst(scheme.count)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: - 実行

    // 今このタブが映しているページの上で走らせる。
    // 呼ぶ前に「映すものがあるか」を確かめること (Tab.open(bookmark:) が見ている)
    @MainActor
    static func run(_ source: String, on webView: WKWebView) {
        webView.evaluateJavaScript(source, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                // ページ側の CSP に弾かれた、綴りが壊れている、など。
                // 利用者が自分で棚に入れたものなので、綴りは伏せずに出す
                Self.log.error("ブックマークレットが走らなかった: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 百分率の戻し

    // %XX が揃っている組だけを一文字に畳み、揃っていない % はそのまま残す。
    // 畳んだ後の並びを UTF-8 として読むので、%E3%81%82 のような多バイトの一文字も正しく戻る
    static func decodePercent(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "%")) else { return text }

        let input = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)

        var i = 0
        while i < input.count {
            if input[i] == UInt8(ascii: "%"), i + 2 < input.count,
               let high = hexDigit(input[i + 1]), let low = hexDigit(input[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(input[i])
                i += 1
            }
        }

        // 戻した結果が UTF-8 として壊れていても String(decoding:) は投げない。
        // 読めない箇所だけが U+FFFD に化ける
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
