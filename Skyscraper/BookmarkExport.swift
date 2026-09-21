//
//  BookmarkExport.swift
//  Skyscraper
//
//  棚ごと他所へ渡す。BookmarkImport.swift の裏返し。
//
//  書き出すのは取り込みと同じ Netscape Bookmark File——Safari・Chrome・
//  Firefox・Edge が揃って読める唯一の形式で、事実上の共通語になっている。
//  閉じない <DT> と <p> が混ざる通りこれは正しい HTML ではないが、
//  ここで綺麗な HTML を書くと読み手の方が受け付けない。慣例に倣う。
//
//  階層は Bookmark.folder の道筋から組み直す。組み直しは BookmarkTree に
//  任せる——帯とメニューが使っているものと同じ道具なので、書き出した並びは
//  画面で見えている並びと必ず一致する。
//
//  最外側は PERSONAL_TOOLBAR_FOLDER="true" の入れ物で包む。こちらの帯は
//  他所のブラウザの「ブックマークバー」に当たるから、この印を付けておくと
//  読み手が棚の奥ではなく帯へ並べてくれる。取り込み側 (BookmarkImport) は
//  この印の付いた入れ物を素通しする造りなので、書き出して取り込み直しても
//  階層は元のままになる。
//
//  ADD_DATE は書かない。Bookmark が日付を持っていないためで、0 や今日の
//  日付で埋めると「いつ登録したか」の嘘になる。属性が無いこと自体は、
//  どの読み手も許している。
//
//  題や見出しの英語 (Bookmarks / Bookmarks Bar) は String(localized:) で
//  包んでいない。これは人へ見せる文言ではなく、他所のブラウザが読む札だから。
//  Chrome も Firefox も、界面の言語に関わらずこの綴りで書き出す。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum BookmarkExport {

    // MARK: - 組み立て

    // 棚まるごとを一枚の文書にする。
    // 盤を出さずに中身だけ取れるので、試すのもここを呼べばいい
    static func html(from bookmarks: [Bookmark]) -> String {
        var out = ""
        out += "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
        out += "<!-- This is an automatically generated file.\n"
        out += "     It will be read and overwritten.\n"
        out += "     DO NOT EDIT! -->\n"
        out += "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
        out += "<TITLE>Bookmarks</TITLE>\n"
        out += "<H1>Bookmarks</H1>\n\n"
        out += "<DL><p>\n"
        out += "    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks Bar</H3>\n"
        out += "    <DL><p>\n"
        append(BookmarkTree.build(bookmarks), depth: 2, to: &out)
        out += "    </DL><p>\n"
        out += "</DL><p>\n"
        return out
    }

    // 一階層ぶんを書き、フォルダに当たったら中へ降りる。
    // 字下げは読み手にとっては意味を持たないが、書き出した物を人が
    // 開いた時に階層が目で追える
    private static func append(_ entries: [BookmarkEntry],
                               depth: Int,
                               to out: inout String) {
        let pad = String(repeating: "    ", count: depth)

        for entry in entries {
            switch entry {
            case .item(let bookmark):
                // javascript: の一件——ブックマークレットもそのまま出す。
                // 他所のブラウザでも普通のブックマークと同じ棚に並ぶ
                out += "\(pad)<DT><A HREF=\"\(escape(bookmark.url))\">\(escape(bookmark.title))</A>\n"

            case .folder(let folder):
                out += "\(pad)<DT><H3>\(escape(folder.name))</H3>\n"
                out += "\(pad)<DL><p>\n"
                append(folder.entries, depth: depth + 1, to: &out)
                out += "\(pad)</DL><p>\n"
            }
        }
    }

    // 属性値にも本文にも同じものを通す。<A HREF="…"> の中身は二重引用符で
    // 括っているので、綴りに " が混ざると其処で属性が切れてしまう。
    // ' は括りに使っていないから触らない。
    //
    // & を最初に置き換えるのは順序が要るため。後回しにすると、
    // 先に置いた &lt; の & まで二度漬けして &amp;lt; になる
    private static func escape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    // MARK: - 入口

    // 置き場所を選ばせて書き出す。
    // メニューと管理の盤から呼ぶので、知らせる場所が他に無い
    @MainActor
    static func chooseFile(from store: BookmarkStore) {
        let bookmarks = store.bookmarks

        // 空のまま盤を出すと、名前を付けて保存させた末に中身の無い
        // 文書が残る。先に断る
        guard !bookmarks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "There are no bookmarks to export.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName()
        panel.message = String(localized: "Choose where to save the bookmarks file.")
        panel.prompt = String(localized: "Export")

        guard panel.runModal() == .OK, let file = panel.url else { return }

        do {
            try html(from: bookmarks).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Nothing was exported.")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    // 名前に日付を入れておく。幾つも書き溜まった時、どれが新しいかを
    // 中身を開かずに見分けられる。
    //
    // en_US_POSIX に固定してあるのは、暦の設定が和暦の時に
    // 「令和8年」の類が綴りへ混ざるのを防ぐため
    private static func suggestedName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Skyscraper Bookmarks \(formatter.string(from: Date())).html"
    }
}
