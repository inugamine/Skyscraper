//
//  BookmarkImport.swift
//  Skyscraper
//
//  他所で貯めたブックマークを引き取る。
//
//  受けるのは Netscape Bookmark File——1990 年代の Netscape Navigator が
//  吐いていた形式で、Safari・Chrome・Firefox・Edge が今も揃ってこれを
//  書き出す。事実上の共通語だ。中身はこういう体裁になっている：
//
//      <!DOCTYPE NETSCAPE-Bookmark-file-1>
//      <DL><p>
//          <DT><H3 ADD_DATE="...">フォルダ</H3>
//          <DL><p>
//              <DT><A HREF="https://example.com" ADD_DATE="...">題</A>
//          </DL><p>
//      </DL><p>
//
//  閉じない <DT> と <p> が混ざる通り、これは正しい HTML ではない。
//  XMLParser に噛ませても最初の <p> で折れるので、<A HREF> を順に
//  拾う自前の走査で読む。
//
//  フォルダは Bookmark.folder に道筋として持たせる。階層の器は作らない
//  （BookmarkFolders.swift が描く直前に組み直す）。
//  書き出し元の「ブックマークバー」だけは入れ物を作らず、
//  中身をこちらの帯の直下へ出す。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum BookmarkImport {

    struct Result {
        let imported: Int
        let skipped: Int
    }

    enum Failure: LocalizedError {
        case unreadable
        case noBookmarks

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return String(localized: "Could not read that file.")
            case .noBookmarks:
                return String(localized: "That file has no bookmarks in it.")
            }
        }
    }

    // MARK: - 取り込み

    @MainActor
    static func run(from file: URL, into store: BookmarkStore) throws -> Result {
        guard let html = read(file) else { throw Failure.unreadable }

        let found = parse(html)
        guard !found.isEmpty else { throw Failure.noBookmarks }

        let imported = store.merge(found)
        return Result(imported: imported, skipped: found.count - imported)
    }

    // MARK: - 走査

    // <A HREF="…">題</A> を書かれた順に拾い、<H3> と <DL> の出入りで
    // 今どのフォルダの中に居るかを数える。
    //
    //     <DT><H3>仕事</H3>      ← 次の <DL> に入る名前を控える
    //     <DL><p>                ← ここで積む
    //         <DT><A …>          ← folder == ["仕事"]
    //     </DL><p>               ← ここで降ろす
    //
    // 属性の並びも引用符の種類も書き出し元によって違うので、
    // href だけを名指しで抜き、残りの属性（ADD_DATE, ICON など）は読み捨てる
    static func parse(_ html: String) -> [Bookmark] {
        let pattern = #"<h3([^>]*)>(.*?)</h3>|<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s">]+))[^>]*>(.*?)</a\s*>|<dl\b[^>]*>|</dl\s*>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let text = html as NSString
        var found: [Bookmark] = []

        // 今居る場所。nil は「素通しの入れ物」で、道筋には現れない
        //（最外側の <DL> と、ブックマークバー相当のフォルダ）
        var stack: [String?] = []
        // 直前の <H3>。次に <DL> が来たらこれがその入れ物の名前になる
        var pendingName: String?
        var hasPending = false

        regex.enumerateMatches(in: html,
                               range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }

            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }

            // ── 見出し（フォルダ名）──
            if let attributes = group(1), let rawName = group(2) {
                let name = plainText(rawName)
                // PERSONAL_TOOLBAR_FOLDER="true" は、書き出し元の
                // 「ブックマークバー」そのものだ。こちらの帯に相当するので、
                // 同名のフォルダを一つ作らず中身を直下へ出す。
                // 印は地域言語に依らない（Chrome も Firefox も同じものを付ける）
                let isToolbar = attributes.lowercased().contains("personal_toolbar_folder")
                pendingName = (isToolbar || name.isEmpty) ? nil : name
                hasPending = true
                return
            }

            // ── ブックマーク一件 ──
            if let href = group(3) ?? group(4) ?? group(5) {
                guard let address = webAddress(href) else { return }
                let title = plainText(group(6) ?? "")
                let path = stack.compactMap { $0 }
                found.append(Bookmark(title: title.isEmpty ? fallbackTitle(for: address) : title,
                                      url: address,
                                      folder: path.isEmpty ? nil : path))
                return
            }

            // ── 入れ物の出入り ──
            if text.substring(with: match.range).lowercased().hasPrefix("</") {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                // 直前に見出しが無ければ名無しの器（最外側の <DL> がこれ）
                stack.append(hasPending ? pendingName : nil)
                pendingName = nil
                hasPending = false
            }
        }

        return found
    }

    // 預かるのは web の場所だけ。
    // Firefox の place:（スマートフォルダ）、Chrome の chrome:// や
    // javascript:（ブックマークレット）は、こちらで開いても何も起きない
    private static func webAddress(_ raw: String) -> String? {
        let address = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // 頭の文字列だけを見る。URLComponents に別けさせないのは、
        // パスに生の日本語が入った URL をあれが黙って nil にし得るため。
        // 取りこぼしていいのは開けない仕組みのものだけだ
        let lowered = address.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return nil }
        return address
    }

    // 題の無いブックマークもある。空欄が並ぶよりは場所の名前が出た方がいい
    private static func fallbackTitle(for address: String) -> String {
        URLComponents(string: address)?.host ?? address
    }

    // MARK: - 下ごしらえ

    private static func read(_ file: URL) -> String? {
        if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        // 古い書き出しは Shift_JIS や UTF-16 で来ることがある
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: file, usedEncoding: &encoding)
    }

    // 題に紛れ込んだ札（<B> など）を落として、実体参照を戻す
    private static func plainText(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "<[^>]*>", with: "",
                                                options: [.regularExpression])
        return decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // &amp; の類を戻す。
    //
    // NSAttributedString の HTML 読み込みでも同じことはできるが、
    // あれは一件ごとに WebKit を起こす。千件のブックマークで千回叩く
    // 代物ではないので、必要な分だけ自前で持つ
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var out = ""
        var rest = Substring(text)

        while let ampersand = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<ampersand]
            let body = rest.index(after: ampersand)

            // 実体参照は長くても数文字。それ以上離れた ; は別物なので、
            // & をそのまま文字として通す
            guard let semicolon = rest[body...].firstIndex(of: ";"),
                  rest.distance(from: body, to: semicolon) <= 8
            else {
                out.append("&")
                rest = rest[body...]
                continue
            }

            let name = String(rest[body..<semicolon])
            out += character(for: name) ?? "&\(name);"
            rest = rest[rest.index(after: semicolon)...]
        }

        out += rest
        return out
    }

    private static func character(for name: String) -> String? {
        switch name.lowercased() {
        case "amp":  return "&"
        case "lt":   return "<"
        case "gt":   return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            // 数値参照（&#39; と &#x2F;）
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.lowercased().hasPrefix("x")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }

    // MARK: - 入口

    // ファイルを選ばせて取り込み、結果を一言返す。
    // メニューから呼ぶので、知らせる場所が他に無い
    @MainActor
    static func chooseFile(into store: BookmarkStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a bookmarks file exported from another browser.")
        panel.prompt = String(localized: "Import")

        guard panel.runModal() == .OK, let file = panel.url else { return }

        let alert = NSAlert()
        do {
            let result = try run(from: file, into: store)
            alert.messageText = String(localized: "Took in \(result.imported) bookmarks.")
            if result.skipped > 0 {
                alert.informativeText = String(
                    localized: "\(result.skipped) entries were already saved or could not be used."
                )
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Nothing was imported.")
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
