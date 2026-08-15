//
//  BookmarkFolders.swift
//  Skyscraper
//
//  平坦なブックマークの配列を、描く直前だけ階層に組み直す。
//
//  保存されているのは今まで通り [Bookmark] の一列で、各件が
//  「どのフォルダに居るか」の道筋を持っているだけだ。木は持たない。
//  持たせると、並べ替え・重複判定・保存の全部が木の面倒を見る羽目になる。
//
//  組み直しは描画のたびに走るが、数百件なら一瞬で終わる仕事だ
//  （辞書引きと配列の連結しかしていない）。
//

import SwiftUI

// 帯やメニューに並ぶ一つぶん。ブックマークそのものか、フォルダか
enum BookmarkEntry: Identifiable {
    case item(Bookmark)
    case folder(BookmarkFolder)

    var id: String {
        switch self {
        case .item(let bookmark): return bookmark.id.uuidString
        case .folder(let folder): return folder.id
        }
    }
}

struct BookmarkFolder: Identifiable {
    let id: String        // 道筋を連ねたもの（"仕事/参考"）
    let name: String
    let entries: [BookmarkEntry]
}

enum BookmarkTree {

    // 平坦な一列を階層に組む。
    // 並び順は元の配列の通りで、フォルダは「その中の最初の一件が
    // 現れた場所」に立つ。取り込んだ順＝書き出し元での並びが保たれる
    static func build(_ bookmarks: [Bookmark]) -> [BookmarkEntry] {
        entries(bookmarks, depth: 0, path: [])
    }

    private static func entries(_ bookmarks: [Bookmark],
                                depth: Int,
                                path: [String]) -> [BookmarkEntry] {
        // 一度目：この深さで「直下の一件」と「フォルダの束」に振り分ける。
        // 場所（並び順）を保つため、束も配列の中に居場所を取っておく
        enum Slot {
            case item(Bookmark)
            case folder(String, [Bookmark])
        }

        var slots: [Slot] = []
        var slotOfFolder: [String: Int] = [:]

        for bookmark in bookmarks {
            let folders = bookmark.folder ?? []
            guard folders.count > depth else {
                slots.append(.item(bookmark))
                continue
            }
            let name = folders[depth]
            if let index = slotOfFolder[name], case .folder(_, var members) = slots[index] {
                members.append(bookmark)
                slots[index] = .folder(name, members)
            } else {
                slotOfFolder[name] = slots.count
                slots.append(.folder(name, [bookmark]))
            }
        }

        // 二度目：束の中身を一階層下で組み直す。
        // depth は必ず増えるので、道筋の長さで打ち止めになる
        return slots.map { slot in
            switch slot {
            case .item(let bookmark):
                return .item(bookmark)
            case .folder(let name, let members):
                let childPath = path + [name]
                return .folder(BookmarkFolder(
                    id: childPath.joined(separator: "/"),
                    name: name,
                    entries: entries(members, depth: depth + 1, path: childPath)
                ))
            }
        }
    }
}

// MARK: - メニューの中身

// フォルダの中身をメニュー項目として並べる。入れ子のフォルダは入れ子のメニューになる。
//
// 内側を AnyView で包んでいるのは、自分自身を含む View の型が
// 無限に入れ子になるのを断つため（body の型が自分を参照すると、
// 型検査が終わらない）。包む場所は一段ぶんなので、描画の負担は無い
struct BookmarkMenuItems: View {
    let entries: [BookmarkEntry]
    let open: (Bookmark) -> Void

    var body: some View {
        ForEach(entries) { entry in
            switch entry {
            case .item(let bookmark):
                Button {
                    open(bookmark)
                } label: {
                    Text(verbatim: bookmark.title)
                }
            case .folder(let folder):
                Menu {
                    AnyView(BookmarkMenuItems(entries: folder.entries, open: open))
                } label: {
                    // メニューの中では Label の絵柄が項目の左に並ぶ。
                    // 入れ子の矢印は AppKit が自分で右端に出すので、
                    // こちらは中身が畳まっていることだけを示せばいい
                    Label {
                        Text(verbatim: folder.name)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
        }
    }
}

// ブックマークバーに立つフォルダ。押すと中身が垂れる
struct BookmarkFolderMenu: View {
    let folder: BookmarkFolder
    let open: (Bookmark) -> Void

    var body: some View {
        Menu {
            BookmarkMenuItems(entries: folder.entries, open: open)
        } label: {
            HStack(spacing: 5) {
                // 畳まっていることの印。
                // 平の一件と一目で見分けられるのが仕事だから、線画のフォルダを置く。
                // 色を一段落としてあるのは、帯の文字と同じ重さで入ると
                // 並んだ時に絵だけが浮いて見えるためだ
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(Deco.faintGold)

                Text(verbatim: folder.name)
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: folder.name))
    }
}
