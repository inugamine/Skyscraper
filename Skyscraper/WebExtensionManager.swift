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
//  タブと窓の橋渡し（WebExtensionBridge.swift）、ツールバーの popup、
//  設定ページ、許諾の確認（ExtensionPermissions.swift）、
//  アプリ内からの取り込みと削除まで完了。
//  拡張からの tabs.create() は未確認（uBOL は使わない）。
//
//  ── 読み込みと許諾の順 ──
//  見つけただけでは controller に載せない。載せた時点で
//  DNR もコンテンツスクリプトも動き始める——訊く前に動いているのでは
//  訊く意味が無い。未確認のものは保留にして一覧に出す。
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
        // 許諾の状態。
        //
        // pending は「まだ訊いていない」。controller には載せていない。
        // denied は「訊いて断られた」。どちらも動いていないが、
        // 一覧での見せ方と、次に何が起きるかが違う
        enum Review {
            case pending
            case approved
            case denied
        }

        let id: String            // フォルダ名。一覧の鍵としても使う
        let displayName: String
        let version: String
        let source: Source
        let baseURL: URL
        // 許諾シートが要求権限を読むために持っておく
        let ext: WKWebExtension
        let context: WKWebExtensionContext
        var review: Review
        // approved の時だけ意味を持つ
        var isEnabled: Bool

        // ツールバー（アドレスバー右端）にボタンを出すか。
        // 拡張そのものの有効・無効とは別勘定で、これを倒しても
        // 遮断やコンテンツスクリプトは動き続ける。見た目だけの話
        var showsAction: Bool

        // 実際に動いているか
        var isRunning: Bool { review == .approved && isEnabled }
    }

    // 全タブ・全ウィンドウで一つを共有する。
    // WKWebViewConfiguration.webExtensionController に刺すのは
    // WebView 生成の前でなければならない（生成後の configuration は複製が返る）
    let controller: WKWebExtensionController

    @Published private(set) var loaded: [Loaded] = []

    // 橋渡し側が「拡張が一つでも生きているか」を見るための口。
    // 保留中のものも切られているものも数えない
    var contexts: [WKWebExtensionContext] {
        loaded.filter(\.isRunning).map(\.context)
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

        let userFolders = Self.extensionFolders(in: userDir)
        let bundledFolders = Self.bundledExtensionsDirectory
            .map { Self.extensionFolders(in: $0) } ?? []

        // この仕組みを入れる前から入っていた分を、許可済みとして引き継ぐ。
        // 利用者が自分で入れたもので、現に動いている——
        // 起動したら突然「確認してください」と出るのは筋が悪い。
        // 二度目からは何もしない（一度断ったものが復活しては困る）
        ExtensionPermissionStore.grandfatherIfNeeded(
            ids: (userFolders + bundledFolders).map(\.lastPathComponent)
        )

        // 利用者の分を先に読む。
        // 同じ名前が同梱版にもあれば、こちらが優先される
        for url in userFolders {
            await load(at: url, source: .user)
        }

        for url in bundledFolders {
            let name = url.lastPathComponent
            guard !loaded.contains(where: { $0.id == name }) else {
                print("WebExtension[\(name)]: bundled copy skipped (overridden by user)")
                continue
            }
            await load(at: url, source: .bundled)
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

            // 許諾の記憶を見る。無ければ保留——controller には載せない
            let decision = ExtensionPermissionStore.decision(for: name)
            let allowsPrivate = ExtensionPermissionStore.allowsPrivateData(for: name)

            let review: Loaded.Review
            var enabled = false

            switch decision {
            case nil:
                review = .pending
            case .some(false):
                review = .denied
            case .some(true):
                review = .approved
                // 権限は載せる前に付与する。
                // 切られていても付与だけはやっておく——
                // 後で入に戻した時に context を組み直さずに済む
                Self.applyGrants(ext, to: context, allowsPrivateData: allowsPrivate)
                enabled = !Self.disabledIDs.contains(name)
                if enabled {
                    try controller.load(context)
                }
            }

            loaded.append(Loaded(
                id: name,
                displayName: ext.displayName ?? name,
                version: ext.displayVersion ?? "?",
                source: source,
                baseURL: resourceBaseURL,
                ext: ext,
                context: context,
                review: review,
                isEnabled: enabled,
                showsAction: !Self.hiddenActionIDs.contains(name)
            ))
            let origin = source == .bundled ? "bundled" : "user"
            let state: String
            switch review {
            case .pending:  state = ", awaiting review"
            case .denied:   state = ", denied"
            case .approved: state = enabled ? "" : ", disabled"
            }
            print("WebExtension[\(name)]: loaded (\(ext.displayName ?? "?") \(ext.displayVersion ?? "?"), \(origin)\(state))")
        } catch {
            print("WebExtension[\(name)]: load FAILED: \(error)")
        }
    }

    // 要求された権限を context に付与する。
    //
    // ── 丸ごと通している理由 ──
    // 個別に選べる形にはしていない。拡張は要求した権限が欠けると
    // 黙って壊れることが多く、その壊れ方が利用者から見えない。
    // 「入れるか入れないか」を訊いて、入れるなら要求通りに通す。
    //
    // optional 側も通す。uBOL は遮断レベルが 4 段階あり、
    // 上の段（Optimal / Complete）は optional_host_permissions の
    // <all_urls> を要る——ここを通さないと一番下の段で止まる。
    // 許諾シートでも optional を含めて並べている（通すものを全部見せる）
    private static func applyGrants(_ ext: WKWebExtension,
                                    to context: WKWebExtensionContext,
                                    allowsPrivateData: Bool) {
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for permission in ext.optionalPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.optionalPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }

        // ── プライベートウィンドウでも働かせるか ──
        //
        // false のままだと、拡張にはプライベートの窓も
        // その中のタブも一切見えない。エラーは一つも出ないまま
        // uBOL の遮断だけが黙って効かなくなる——プライベートにした途端
        // 広告が戻るのは、使う側から見れば壊れているのと同じだ。
        //
        // 引き換えに、拡張のバックグラウンドはプライベートのタブの
        // URL を知る。だから許諾シートで個別に訊く。
        //
        // load の前に立てること。載せた後で触ると反映に読み直しが要る
        context.hasAccessToPrivateData = allowsPrivateData
    }

    // MARK: - 許諾

    // 保留中の拡張を通す。許諾シートの「許可」から呼ぶ
    func approve(id: String, allowsPrivateData: Bool) {
        guard let index = loaded.firstIndex(where: { $0.id == id }),
              loaded[index].review != .approved
        else { return }

        let entry = loaded[index]
        ExtensionPermissionStore.record(id: id, allowed: true, privateData: allowsPrivateData)
        Self.applyGrants(entry.ext, to: entry.context, allowsPrivateData: allowsPrivateData)

        // 一度断ってから通した場合、disabledIDs には入っていない。
        // 許したのに切れたままにならないよう、ここでは必ず入にする
        do {
            try controller.load(entry.context)
        } catch {
            print("WebExtension[\(id)]: approve FAILED: \(error)")
            return
        }

        var disabled = Self.disabledIDs
        disabled.remove(id)
        Self.disabledIDs = disabled

        loaded[index].review = .approved
        loaded[index].isEnabled = true
        print("WebExtension[\(id)]: approved (private data: \(allowsPrivateData))")
    }

    // 保留中の拡張を断る。
    //
    // 一覧からは消さない。消すと、気が変わった時に
    // フォルダを置き直すしか道が無くなる
    func deny(id: String) {
        guard let index = loaded.firstIndex(where: { $0.id == id }) else { return }

        // 既に載っていれば降ろす（許可済みを後から断った場合）
        if loaded[index].isRunning {
            try? controller.unload(loaded[index].context)
        }

        ExtensionPermissionStore.record(id: id, allowed: false, privateData: false)
        loaded[index].review = .denied
        loaded[index].isEnabled = false
        print("WebExtension[\(id)]: denied")
    }

    // MARK: - 切り替え

    // 拡張を有効／無効にする。
    //
    // 既に読み込み済みのページには即座には反映されない。
    // DNR のルールもコンテンツスクリプトもページ読み込み時に当たるので、
    // 切り替えた後はリロードが要る（呼ぶ側が案内する）
    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = loaded.firstIndex(where: { $0.id == id }) else { return }
        // まだ訊いていないものと断られたものはここでは動かせない。
        // 通すには許諾シートを通す（approve）
        guard loaded[index].review == .approved else { return }
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

    // MARK: - 取り込みと削除

    // 直近の失敗。一覧の足元に出す。
    // ダイアログで出さないのは、シートの上にシートが重なるのを避けるため
    @Published var lastError: String?

    // フォルダを選んで取り込む。読み込めたらその id を返す（呼ぶ側が許諾シートを開く）。
    //
    // 読み込みはその場でやる。「次の起動で拾う」という以前の制限は
    // 技術的な必然ではなかった——load(at:source:) は実行時にも呼べる
    func addFromPanel() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose an unpacked extension folder (one containing manifest.json).")

        guard await panel.begin() == .OK, let chosen = panel.url else { return nil }
        return await add(folder: chosen)
    }

    // 展開済みのフォルダを取り込む
    func add(folder chosen: URL) async -> String? {
        lastError = nil

        let manifest = chosen.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            lastError = String(localized: "That folder does not contain manifest.json.")
            return nil
        }

        let name = chosen.lastPathComponent
        let userDir = Self.userExtensionsDirectory
        let destination = userDir.appendingPathComponent(name, isDirectory: true)

        // 既に置き場の中にあるものを選んだなら、コピーは要らない
        let alreadyInPlace = chosen.standardizedFileURL == destination.standardizedFileURL

        if !alreadyInPlace {
            // 同じ名前が利用者の置き場にあるなら断る。
            // 黙って上書きすると、入れたつもりの無い版で置き換わる
            if FileManager.default.fileExists(atPath: destination.path) {
                lastError = String(localized: "An extension named “\(name)” is already installed. Remove it first.")
                return nil
            }
            do {
                try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: chosen, to: destination)
            } catch {
                lastError = String(localized: "Could not copy the extension: \(error.localizedDescription)")
                return nil
            }
        }

        // 同梱版と同じ名前なら、同梱版を降ろして入れ替える。
        //（同梱版より新しい uBOL を自分で入れたい場合の道）
        if let index = loaded.firstIndex(where: { $0.id == name }) {
            if loaded[index].isRunning {
                try? controller.unload(loaded[index].context)
            }
            loaded.remove(at: index)
        }

        // 名前が同じでも中身は別物かもしれない。
        // 前の許可を引き継がせず、必ず許諾シートを通す
        ExtensionPermissionStore.forget(id: name)

        await load(at: destination, source: .user)

        guard loaded.contains(where: { $0.id == name }) else {
            lastError = String(localized: "The extension could not be loaded. Check the manifest for errors.")
            return nil
        }
        return name
    }

    // 利用者が入れた拡張を消す。同梱版は消せない（消しても次の起動で戻るだけだ）。
    //
    // フォルダはゴミ箱へ。間違えて押した時に取り返しがつく形にしておく
    func remove(id: String) {
        lastError = nil
        guard let index = loaded.firstIndex(where: { $0.id == id }),
              loaded[index].source == .user
        else { return }

        let entry = loaded[index]
        if entry.isRunning {
            try? controller.unload(entry.context)
        }

        do {
            try FileManager.default.trashItem(at: entry.baseURL, resultingItemURL: nil)
        } catch {
            lastError = String(localized: "Could not remove the extension: \(error.localizedDescription)")
            // 降ろしたのに消せなかった。載せ直して元に戻す
            if entry.isRunning { try? controller.load(entry.context) }
            return
        }

        ExtensionPermissionStore.forget(id: id)
        var disabled = Self.disabledIDs
        disabled.remove(id)
        Self.disabledIDs = disabled
        var hidden = Self.hiddenActionIDs
        hidden.remove(id)
        Self.hiddenActionIDs = hidden

        loaded.remove(at: index)
        print("WebExtension[\(id)]: removed")

        // 同じ名前の同梱版があれば、そちらを戻す。
        // 利用者版で上書きしていた場合、消したら同梱版が復活するのが自然だ
        if let bundledDir = Self.bundledExtensionsDirectory {
            let bundled = bundledDir.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
                Task { await load(at: bundled, source: .bundled) }
            }
        }
    }

    func unloadAll() {
        for entry in loaded where entry.isRunning {
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
