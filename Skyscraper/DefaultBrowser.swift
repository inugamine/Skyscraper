//
//  DefaultBrowser.swift
//  Skyscraper
//
//  「既定のブラウザにする」の申し出。
//
//  macOS は既定ブラウザの変更を、アプリ自身が申し出て利用者が確認ダイアログで
//  承諾する形でしか通さない。外から NSWorkspace を叩いても permErr で蹴られる。
//  だから、この口はアプリの中に無ければ意味がない。
//
//  Info.plist の CFBundleURLTypes で http / https を扱えると名乗っているのが前提だ。
//  名乗っていないアプリがここを呼んでも、システムは相手にしない。
//

import AppKit

@MainActor
enum DefaultBrowser {
    // 判定に使う代表。http と https は別々に登録されるが、
    // 片方だけ既定という状態は利用者から見て意味を成さないので、
    // https を代表として見る
    private static let probe = URL(string: "https://example.com")!

    // 今この Skyscraper が既定か。
    //
    // 番地で照合する。同じバンドルIDの写しが幾つも転がっている場合
    //（DMG の残骸、ゴミ箱の中、書庫の中）、
    // 「Skyscraper が既定」でも「この Skyscraper が既定」とは限らない
    static var isCurrent: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // 今の既定の名前（「Comet」など）。設定画面に出す。
    // displayName(atPath:) は Finder の設定次第で .app を残すので、自分で落とす
    static var currentName: String? {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return handler.deletingPathExtension().lastPathComponent
    }

    // 既定にしてくれと申し出る。
    // 承諾を求めるダイアログはシステムが出すので、こちらでは何も訊かない。
    // 断られた場合もエラーとして返る（利用者の判断であって、失敗ではない）。
    //
    // 申し出るのは http だけだ。
    // macOS は「既定の Web ブラウザ」を http の受け手として一括りに扱い、
    // ダイアログを承諾すると https も一緒に付け替わる。
    // その後で https を別口で申し出ると permErr で蹴られる（macOS 26 で確認）。
    // 二つ並べて申し出ると、通ったのに「失敗」と出る羽目になる
    static func request() async -> Error? {
        let app = Bundle.main.bundleURL
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: app,
                toOpenURLsWithScheme: "http"
            )
        } catch {
            return error
        }
        // https が付いてこなかった時だけ、別口で頼む。
        // 普段はここを通らない
        guard !isCurrent else { return nil }
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: app,
                toOpenURLsWithScheme: "https"
            )
        } catch {
            return error
        }
        return nil
    }
}
