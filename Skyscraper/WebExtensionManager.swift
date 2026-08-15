//
//  WebExtensionManager.swift
//  Skyscraper
//
//  Web Extensions（Chrome/Safari 互換の拡張機能）を読み込んで動かす。
//  実体は WebKit の WKWebExtension 一式（macOS 15.4 / Safari 18.4 で公開）。
//
//  ── 置き場所は二つ ──
//  1. アプリの中（Skyscraper.app/Contents/Resources/Extensions/）
//     標準装備。今は uBlock Origin Lite を同梱している。
//     release.sh がビルド時に放り込む
//  2. ~/Library/Application Support/Skyscraper/Extensions/
//     利用者が自分で足したもの。
//     同じ名前のフォルダが両方にあればこちらが勝つ
//     （同梱版より新しい uBOL を自分で入れたい場合の逃げ道）
//
//  ── 今の範囲 ──
//  タブと窓の橋渡し（WebExtensionBridge.swift）まで完了。
//  ツールバーの popup（サイトごとの遮断レベル切替など）は未実装。
//

import AppKit
import Combine
import Foundation
import WebKit

@MainActor
final class WebExtensionManager: NSObject, ObservableObject {
    static let shared = WebExtensionManager()

    // 拡張の出所
    enum Source {
        case bundled   // アプリに同梱
        case user      // 利用者が入れた
    }

    // 見つかった拡張一枚ぶん。設定画面の一覧に使う。
    //
    // 切られている拡張もここには載る。載せないと一覧から消えて
    // 二度と入れ直せなくなるためで、controller に載せるかどうかだけを
    // isEnabled で切り替える
    struct Loaded: Identifiable {
        let id: String            // フォルダ名。一覧の鍵としても使う
        let displayName: String
        let version: String
        let source: Source
        let baseURL: URL
        let context: WKWebExtensionContext
        var isEnabled: Bool

        // ツールバー（アドレスバー右端）にボタンを出すか。
        // 拡張そのものの有効・無効とは別勘定で、これを倒しても
        // 遮断やコンテンツスクリプトは動き続ける。見た目だけの話
        var showsAction: Bool
    }

    // 全タブ・全ウィンドウで一つを共有する。
    // WKWebViewConfiguration.webExtensionController に刺すのは
    // WebView 生成の前でなければならない（生成後の configuration は複製が返る）
    let controller: WKWebExtensionController

    @Published private(set) var loaded: [Loaded] = []

    // 橋渡し側が「拡張が一つでも生きているか」を見るための口。
    // 切られているものは数えない
    var contexts: [WKWebExtensionContext] {
        loaded.filter(\.isEnabled).map(\.context)
    }

    // loadAll() の二重呼び防止（窓を複数開いても一度だけ）
    private var didLoadAll = false

    // 切られている拡張のフォルダ名。
    // 「切った側」を覚えるのは、新しく入れた拡張が既定で有効になるようにするため
    private static let disabledKey = "skyscraper.extensions.disabled"

    private static var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    // ツールバーのボタンを隠している拡張のフォルダ名。
    // 切った側を覚えるのは disabledIDs と同じ理由で、
    // 新しく入れた拡張のボタンは既定で出す
    private static let hiddenActionKey = "skyscraper.extensions.hiddenAction"

    private static var hiddenActionIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenActionKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenActionKey) }
    }

    private override init() {
        // .default() は永続。拡張側の storage API の中身がアプリに紐付いて残る
        let configuration = WKWebExtensionController.Configuration.default()
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: - 置き場所

    // 利用者が自分で拡張を放り込む場所。
    // 設定画面の「フォルダを開く」がここを指す
    static var userExtensionsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Skyscraper", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }

    // アプリに同梱した拡張の置き場。
    // 開発中（release.sh を通さず Xcode から直に走らせた場合）は
    // 存在しないことがあるので、無ければ黙って飛ばす
    static var bundledExtensionsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true)
    }

    // MARK: - 読み込み

    // 両方の置き場を浚って、見つかった拡張を全部読み込む。
    // アプリ起動時に一度だけ呼ぶ。
    // WKWebExtension の生成が async なのでこちらも async。
    // 遅れて読み込んでも問題はない——controller 自体は起動時点で
    // 既に全 WKWebView に刺さっていて、中身は後から増やせる
    func loadAll() async {
        guard !didLoadAll else { return }
        didLoadAll = true

        let userDir = Self.userExtensionsDirectory
        // 無ければ作っておく。Finder で開いて放り込めるように
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        // 利用者の分を先に読む。
        // 同じ名前が同梱版にもあれば、こちらが優先される
        for url in Self.extensionFolders(in: userDir) {
            await load(at: url, source: .user)
        }

        if let bundledDir = Self.bundledExtensionsDirectory {
            for url in Self.extensionFolders(in: bundledDir) {
                let name = url.lastPathComponent
                guard !loaded.contains(where: { $0.id == name }) else {
                    print("WebExtension[\(name)]: bundled copy skipped (overridden by user)")
                    continue
                }
                await load(at: url, source: .bundled)
            }
        }

        print("WebExtensionManager: loaded \(loaded.count) extension(s)")
    }

    // 下に manifest.json を持つフォルダだけを拾う
    private static func extensionFolders(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries.filter { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { return false }
            let manifest = entry.appendingPathComponent("manifest.json")
            return FileManager.default.fileExists(atPath: manifest.path)
        }
        // 一覧の並びを起動ごとに変えない
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // 展開済みの拡張フォルダを一つ読み込む
    func load(at resourceBaseURL: URL, source: Source) async {
        let name = resourceBaseURL.lastPathComponent
        do {
            let ext = try await WKWebExtension(resourceBaseURL: resourceBaseURL)

            // manifest の解釈で拾った不備。致命でなくても出しておく
            // （権限名の綴り違いなどは黙って無視されるので、これが唯一の手がかりになる）
            for error in ext.errors {
                print("WebExtension[\(name)]: manifest warning: \(error)")
            }

            let context = WKWebExtensionContext(for: ext)

            // 識別子は起動をまたいで同じにする。
            // 既定では毎回ちがう UUID が振られるので、そのままだと
            // 拡張側の設定（uBOL の遮断レベルなど）が毎回まっさらに戻る。
            // フォルダ名だけで作るのは意図的で、同梱版を利用者版で上書きしても
            // 設定が引き継がれる
            context.uniqueIdentifier = "net.live-on.inugamine.Skyscraper.extension.\(name)"

            // ── 要求された権限を丸ごと通す ──
            // 自分が同梱したものと、利用者が自分で置いたものしか読まない。
            // 取り込み UI を作る段になったら、ここを許諾ダイアログに差し替える
            for permission in ext.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in ext.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            // optional 側も通す。
            // uBOL は遮断レベルが 4 段階あり、上の段（Optimal / Complete）は
            // optional_host_permissions の <all_urls> を要る。
            // ここを通さないと一番下の段だけで止まる
            for permission in ext.optionalPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in ext.optionalPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }

            // 切られていなければ controller に載せる。
            // 切られていても一覧には出すので、context 自体は作って手元に持つ
            let enabled = !Self.disabledIDs.contains(name)
            if enabled {
                try controller.load(context)
            }
            loaded.append(Loaded(
                id: name,
                displayName: ext.displayName ?? name,
                version: ext.displayVersion ?? "?",
                source: source,
                baseURL: resourceBaseURL,
                context: context,
                isEnabled: enabled,
                showsAction: !Self.hiddenActionIDs.contains(name)
            ))
            let origin = source == .bundled ? "bundled" : "user"
            let state = enabled ? "" : ", disabled"
            print("WebExtension[\(name)]: loaded (\(ext.displayName ?? "?") \(ext.displayVersion ?? "?"), \(origin)\(state))")
        } catch {
            print("WebExtension[\(name)]: load FAILED: \(error)")
        }
    }

    // MARK: - 切り替え

    // 拡張を有効／無効にする。
    //
    // 既に読み込み済みのページには即座には反映されない。
    // DNR のルールもコンテンツスクリプトもページ読み込み時に当たるので、
    // 切り替えた後はリロードが要る（呼ぶ側が案内する）
    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = loaded.firstIndex(where: { $0.id == id }) else { return }
        guard loaded[index].isEnabled != enabled else { return }

        let context = loaded[index].context
        do {
            if enabled {
                try controller.load(context)
            } else {
                try controller.unload(context)
            }
        } catch {
            print("WebExtension[\(id)]: \(enabled ? "enable" : "disable") FAILED: \(error)")
            return
        }

        loaded[index].isEnabled = enabled

        var disabled = Self.disabledIDs
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        Self.disabledIDs = disabled

        print("WebExtension[\(id)]: \(enabled ? "enabled" : "disabled")")
    }

    // ツールバーにボタンを出すかどうかだけを切り替える。
    //
    // controller には触らない。拡張は載ったまま動き続け、
    // 消えるのはボタンだけなのでリロードも要らない。
    //
    // 注意：popup しか入口を持たない拡張（uBOL の遮断レベル切替など）は、
    // ボタンを隠すと設定に触る手立てが無くなる。呼ぶ側で一言添えること
    func setShowsAction(_ shows: Bool, for id: String) {
        guard let index = loaded.firstIndex(where: { $0.id == id }) else { return }
        guard loaded[index].showsAction != shows else { return }

        loaded[index].showsAction = shows

        var hidden = Self.hiddenActionIDs
        if shows {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        Self.hiddenActionIDs = hidden

        print("WebExtension[\(id)]: action \(shows ? "shown" : "hidden")")
    }

    // 利用者の拡張フォルダを Finder で開く。
    // 無ければ先に作る
    func revealUserExtensionsDirectory() {
        let dir = Self.userExtensionsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func unloadAll() {
        for entry in loaded where entry.isEnabled {
            try? controller.unload(entry.context)
        }
        loaded.removeAll()
    }
}

// MARK: - WKWebExtensionControllerDelegate

// 拡張から「今開いている窓はどれか」を問われた時の答え。
// これが無いと tabs.query() が空を返し、コンテンツスクリプトの
// runtime.sendMessage() が "Tab not found" で弾かれる
extension WebExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext)
        -> [any WKWebExtensionWindow] {
        TabManager.openWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor context: WKWebExtensionContext)
        -> (any WKWebExtensionWindow)? {
        // 手前の窓を探す。見つからなければ名簿の先頭を返す
        let windows = TabManager.openWindows
        return windows.first { manager in
            manager.selectedTab?.webView.window?.isKeyWindow == true
        } ?? windows.first
    }

    // アイコンやバッジが変わった。
    //
    // uBOL はページごとに遮断数をバッジへ出すので、ここが頻繁に呼ばれる。
    // action はタブごとに違う実体なので、associatedTab を見て
    // 該当する Tab に直接知らせる（全タブを起こすと無駄が多い）
    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        guard let tab = action.associatedTab as? Tab else { return }
        tab.extensionActionsDidChange()
    }

    // 拡張が popup を出したいと言ってきた。
    //
    // ツールバーのボタンを押して performAction(for:) を呼んだ場合も、
    // 拡張側の JS が自発的に開こうとした場合も、どちらもここに来る。
    //
    // NSPopover は WebKit が組み立て済みで action.popupPopover に入っている。
    // 中身の WebView も寸法調整も自動で、閉じれば closePopup() まで呼ばれる。
    // こちらの仕事は「どのビューの横に出すか」を決めることだけだ
    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }

        // ボタンの実体を探す。
        // 鍵は uniqueIdentifier（登録側と必ず揃えること）
        let anchor = ExtensionActionAnchorRegistry.shared.view(
            forExtension: context.uniqueIdentifier
        )

        if let anchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let webView = (action.associatedTab as? Tab)?.webView,
                  webView.window != nil {
            // ボタンの実体が掴めなかった場合の逃げ道。
            // WebView の上端中央を基準にする——contentView を使うと
            // 座標系の上下で窓の外に出てしまう
            let rect = CGRect(x: webView.bounds.midX - 1, y: 0, width: 2, height: 2)
            popover.show(relativeTo: rect, of: webView, preferredEdge: .maxY)
        }

        completionHandler(nil)
    }

    // 拡張の設定ページを開きたい。
    //
    // uBOL の popup 右下の歯車から runtime.openOptionsPage() が呼ばれ、
    // ここが未実装だと "It is not implemented" で弾かれる。
    //
    // 設定ページは webkit-extension:// スキームで、
    // 拡張専用の configuration で作った WebView からしか開けない。
    // 通常のタブでは遷移が取り消されるので、専用の窓を立てる
    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if WebExtensionOptionsWindowController.shared.show(for: context) {
            completionHandler(nil)
        } else {
            completionHandler(NSError(
                domain: "net.live-on.inugamine.Skyscraper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The options page could not be opened."]
            ))
        }
    }
}
