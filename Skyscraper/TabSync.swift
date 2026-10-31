//
//  TabSync.swift
//  Skyscraper
//
//  開いているタブを iCloud (CloudKit) で他の Mac と見せ合う。
//  他の Mac で開いているタブは、ロビー (新規タブの盤) に並ぶ。Safari と同じ作り。
//
//  ── 置き方 ──
//  ブックマーク同期 (BookmarkSync.swift) と同じ入れ物に、タブ専用のゾーン
//  「OpenTabs」を置き、Mac ごとにレコードを一件持つ。名前はその Mac の
//  控え番号 (起動して初めて作る UUID)。中身は Mac の名前・送った時刻・
//  タブの一覧を JSON の塊にして payload という箱一つに入れる。
//  理由はブックマークと同じ——本番へ流したスキーマは取り消せないので、
//  向こうに見せる箱は少ない方がいい。
//
//  Mac ごとに分けるのは、二台が同じレコードを取り合わないため。
//  自分のレコードには自分しか書かないので、後勝ちで誰かの分が消えることが無い。
//
//  他の Mac の分は「ゾーンの中身を全部くれ」(recordZoneChanges) で集める。
//  普通の検索 (CKQuery) だと、Dashboard で recordName に索引を立てる手間が要る。
//
//  ── 送る・取りに行く ──
//  送るのはタブの出入りとページの移動のたび (セッションの保存と同じ合図)。
//  五秒まとめてから送り、中身が前に送ったものと同じなら通信しない。
//
//  取りに行くのは三つの場面。
//  - 他の Mac が送った時。ゾーンに知らせ (CKRecordZoneSubscription) を出してあり、
//    iCloud がプッシュ通知で起こしに来る (AppDelegate が取り次ぐ)。数秒で揃う
//  - アプリが手前に戻った時 (知らせが届かなかった時の保険)
//  - ロビーを開いた時
//
//  知らせは中身の無い「起こすだけ」のもの (content-available)。
//  利用者に通知の許可を訊く盤は出ない。
//
//  ── 試す時の癖 ──
//  Debug の版は CloudKit の Development に繋がり、知らせは APNs の試験用の
//  経路で来る。ところが Skyscraper は Debug でも Developer ID で署名するので、
//  受け口は本番用 (aps-environment = production) になり、知らせが届かない。
//  知らせを試す時は、二台とも Release 構成で動かすこと
//
//  ── 送らないもの ──
//  プライベートウインドウのタブ、ロビー、http(s) 以外の頁。
//
//  ── 本番へ流す前に ──
//  OpenTabList というレコードの型が新しく生まれるので、配る前に
//  CloudKit Dashboard で Development から Production へスキーマを上げること
//

import AppKit
import CloudKit
import Combine
import Foundation
import SwiftUI
import SystemConfiguration
import WebKit
import os

@MainActor
final class TabSync: ObservableObject {
    static let shared = TabSync()

    // 設定画面から入り切りする鍵。既定は入り
    static let enabledKey = "skyscraper.tabs.sync.enabled"

    private static let containerID = "iCloud.net.live-on.inugamine.Skyscraper"
    private static let zoneName = "OpenTabs"
    private static let recordType = "OpenTabList"
    // この Mac の控え番号を覚えておく鍵
    private static let deviceKey = "skyscraper.tabs.sync.deviceID"
    // 一台ぶんに載せるタブの上限。百枚あれば誰の用も足りる
    private static let tabLimit = 100
    // これより長く便りの無い Mac は、もう使っていないと見なして並べない
    private static let staleAfter: TimeInterval = 30 * 24 * 60 * 60
    // ロビーを開くたびに取りに行くと、新規タブ一枚ごとに通信が飛ぶ。
    // 前に取ってからこれだけ経つまでは、手元の分で済ませる
    private static let refreshInterval: TimeInterval = 30

    private static let log = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                                    category: "TabSync")

    // ── 見せ合う中身 ──

    struct RemoteTab: Codable, Hashable {
        let title: String
        let url: String
    }

    private struct Payload: Codable {
        let deviceName: String
        let updatedAt: Date
        let tabs: [RemoteTab]
    }

    struct RemoteDevice: Identifiable {
        let id: String
        // 空なら名前が取れなかった Mac。ロビーでは「Other Mac」と出す
        let name: String
        let updatedAt: Date
        let tabs: [RemoteTab]
    }

    // 他の Mac (送った時刻の新しい順)。ロビーが見張る
    @Published private(set) var devices: [RemoteDevice] = []

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: TabSync.zoneName)
    private let deviceID: String

    private var zoneReady = false
    // ゾーンの変更を知らせてもらう注文の名前。どの Mac も同じ名前で出す
    // (注文は Mac ごとではなく iCloud アカウントに付き、プッシュの宛先は端末ごとに届く)
    private static let subscriptionID = "open-tabs-changes"
    private var subscriptionReady = false
    // 取りに行っている最中に知らせが来たら、終わった後にもう一度行く
    private var needsAnotherPull = false
    // 直近に触った自分のレコード (印 recordChangeTag を持ち回るため)
    private var known: CKRecord?
    // 最後に送った中身 (Mac の名前とタブ)。同じなら送らない
    private var sentName: String?
    private var sentTabs: [RemoteTab]?
    private var lastRefresh: Date?

    private var debounce: Task<Void, Never>?
    private var pushing: Task<Void, Never>?
    private var pulling: Task<Void, Never>?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private init() {
        container = CKContainer(identifier: Self.containerID)
        database = container.privateCloudDatabase
        if let saved = UserDefaults.standard.string(forKey: Self.deviceKey) {
            deviceID = saved
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: Self.deviceKey)
            deviceID = fresh
        }
    }

    // MARK: - 出入りの合図

    func start() {
        // 手前に戻るたびに取りに行く。起動直後にも一度飛んでくる
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(force: true)
            }
        }
        Task { await ensureSubscription() }
    }

    // ── プッシュ通知の取り次ぎ (AppDelegate から) ──

    func remoteNotificationsRegistered() {
        Self.log.info("プッシュ通知の宛先を受け取った")
    }

    func remoteNotificationsFailed(_ error: Error) {
        report("プッシュ通知の宛先の登録", error)
    }

    // iCloud からの知らせ。うちの注文の分なら、すぐ取りに行く
    func handleRemoteNotification(_ userInfo: [String: Any]) {
        let dictionary = userInfo as [AnyHashable: Any]
        guard let notification = CKNotification(fromRemoteNotificationDictionary: dictionary),
              notification.subscriptionID == Self.subscriptionID else { return }
        Self.log.debug("他の Mac がタブを送った知らせ")
        refresh(force: true)
    }

    // タブが動いたので送る。TabManager のセッション保存と同じ所から呼ばれる。
    // 五秒待つのは、タブを続けて閉じたりページを渡り歩いたりする間に
    // 一手ごとの送信が起きるのを避けるため
    func scheduleUpload() {
        guard isEnabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.upload()
        }
    }

    // ロビーを開いた時。前に取ってから間が無ければ見送る
    func refreshIfStale() {
        refresh(force: false)
    }

    // 設定で入り切りされた時。
    // 切ったら、このMacの分を iCloud から消す——他の Mac のロビーにも出なくなる
    func settingChanged() {
        if isEnabled {
            Self.log.info("タブの同期を入れた")
            sentTabs = nil
            sentName = nil
            scheduleUpload()
            refresh(force: true)
            Task { await ensureSubscription() }
        } else {
            Self.log.info("タブの同期を止めた")
            debounce?.cancel()
            devices = []
            Task { await removeOwnRecord() }
        }
    }

    private func refresh(force: Bool) {
        guard isEnabled else { return }
        // 取りに行っている最中。知らせを捨てず、終わった後にもう一度行く
        if pulling != nil {
            if force { needsAnotherPull = true }
            return
        }
        if !force, let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        pulling = Task { [weak self] in
            await self?.pull()
            guard let self else { return }
            self.pulling = nil
            if self.needsAnotherPull {
                self.needsAnotherPull = false
                self.refresh(force: true)
            }
        }
    }

    private func upload() {
        pushing?.cancel()
        pushing = Task { [weak self] in
            await self?.push()
            self?.pushing = nil
        }
    }

    // MARK: - 手元のタブ

    // 送る一覧。最近触った順に並べる (ロビーでもこの順に出る)
    private func localTabs() -> [RemoteTab] {
        let tabs = TabManager.openWindows
            .filter { !$0.isPrivate }
            .flatMap(\.tabs)
            .filter { !$0.isHome }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }

        var result: [RemoteTab] = []
        var seen = Set<String>()
        for tab in tabs {
            // 畳んだタブは WebView が空なので、控えてある番地を使う
            let address = tab.isUnloaded
                ? tab.urlText
                : (tab.webView.url?.absoluteString ?? tab.urlText)
            guard let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(address) else { continue }
            seen.insert(address)
            let title = tab.pageTitle.isEmpty ? (url.host() ?? address) : tab.pageTitle
            result.append(RemoteTab(title: title, url: address))
            if result.count >= Self.tabLimit { break }
        }
        return result
    }

    // この Mac の名前。システム設定の「一般 › 情報 › 名前」。
    // Host.current().localizedName は名前解決で待たされることがあるので使わない
    private func localName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
    }

    // MARK: - 送る

    private func push() async {
        guard isEnabled, await isUsable, await ensureZone() else { return }
        let tabs = localTabs()
        let name = localName()
        guard tabs != sentTabs || name != sentName else {
            Self.log.debug("タブが動いていないので送らない")
            return
        }
        let payload = Payload(deviceName: name, updatedAt: Date(), tabs: tabs)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        let recordID = CKRecord.ID(recordName: deviceID, zoneID: zoneID)
        let record = known ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["payload"] = data as CKRecordValue

        do {
            known = try await database.save(record)
            sentTabs = tabs
            sentName = name
            Self.log.info("\(tabs.count) 枚を送った")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 手元の印が古かった。書くのは自分だけなので、サーバの版を土台に塗り直す
            guard let server = error.serverRecord else { return report("送信", error) }
            server["payload"] = data as CKRecordValue
            do {
                known = try await database.save(server)
                sentTabs = tabs
                sentName = name
            } catch {
                report("送信のやり直し", error)
            }
        } catch {
            report("送信", error)
        }
    }

    private func removeOwnRecord() async {
        guard await isUsable else { return }
        let recordID = CKRecord.ID(recordName: deviceID, zoneID: zoneID)
        do {
            _ = try await database.deleteRecord(withID: recordID)
            Self.log.info("この Mac の分を消した")
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // もともと無い
        } catch {
            report("この Mac の分の削除", error)
        }
        known = nil
        sentTabs = nil
        sentName = nil
    }

    // MARK: - 取りに行く

    private func pull() async {
        guard isEnabled, await isUsable else { return }
        lastRefresh = Date()

        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        do {
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result {
                        records.append(modification.record)
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            // まだどの Mac も送っていない
            devices = []
            return
        } catch {
            report("取り込み", error)
            return
        }

        let now = Date()
        devices = records.compactMap { record -> RemoteDevice? in
            guard record.recordID.recordName != deviceID,
                  let data = record["payload"] as? Data,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  !payload.tabs.isEmpty,
                  now.timeIntervalSince(payload.updatedAt) < Self.staleAfter else { return nil }
            return RemoteDevice(id: record.recordID.recordName,
                                name: payload.deviceName,
                                updatedAt: payload.updatedAt,
                                tabs: payload.tabs)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
        Self.log.debug("他の Mac \(self.devices.count) 台ぶんを受け取った")
    }

    // MARK: - 下ごしらえ

    // ゾーンを用意する。既にあっても保存は通るので、起動ごとに一度だけ呼べばいい
    private func ensureZone() async -> Bool {
        if zoneReady { return true }
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)],
                                                     deleting: [])
            zoneReady = true
            return true
        } catch {
            report("ゾーンの用意", error)
            return false
        }
    }

    // ゾーンの変更を知らせてもらう注文を出す。
    // 同じ名前で出し直しても上書きになるだけなので、起動ごとに一度出して構わない
    private func ensureSubscription() async {
        guard isEnabled, !subscriptionReady, await isUsable, await ensureZone() else { return }
        let subscription = CKRecordZoneSubscription(zoneID: zoneID,
                                                    subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        // 中身の無い「起こすだけ」の知らせ。盤も音も出さない
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
            subscriptionReady = true
            Self.log.info("ゾーンの変更の知らせを注文した")
        } catch {
            report("知らせの注文", error)
        }
    }

    // iCloud が使えない人の所では黙って何もしない (BookmarkSync と同じ)
    private var isUsable: Bool {
        get async {
            (try? await container.accountStatus()) == .available
        }
    }

    private func report(_ what: String, _ error: Error) {
        if let ckError = error as? CKError {
            Self.log.error("\(what)に失敗 — CKError \(ckError.errorCode): \(ckError.localizedDescription)")
        } else {
            Self.log.error("\(what)に失敗 — \(error.localizedDescription)")
        }
    }
}

// MARK: - ロビーの「他の Mac のタブ」

struct RemoteTabsSection: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var sync = TabSync.shared

    // 「もっと見る」で開いた Mac
    @State private var expanded: Set<String> = []
    // 一覧の中身の高さ。これと上限の小さい方を枠の高さにする——
    // 少ない時は詰め、「もっと見る」で伸びた時だけ枠の中で転がす
    @State private var contentHeight: CGFloat = 0
    private static let maxHeight: CGFloat = 300

    // 一台ぶんで最初に見せる枚数
    private static let collapsedCount = 6

    var body: some View {
        if !sync.devices.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sync.devices) { device in
                        deviceBlock(device)
                    }
                }
                .padding(.horizontal, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollIndicators(.never)
            .frame(width: 520, height: min(max(contentHeight, 1), Self.maxHeight))
        }
    }

    private func deviceBlock(_ device: TabSync.RemoteDevice) -> some View {
        let isExpanded = expanded.contains(device.id)
        let shown = isExpanded ? device.tabs : Array(device.tabs.prefix(Self.collapsedCount))
        return VStack(alignment: .leading, spacing: 2) {
            // 見出し。縦タブのグループ見出しと同じ、菱形と細い罫
            HStack(spacing: 8) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 5))
                    .foregroundColor(Deco.gold)
                Text(device.name.isEmpty ? String(localized: "Other Mac") : device.name)
                    .font(.system(size: 11, design: .serif))
                    .tracking(2)
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Deco.faintGold).frame(height: 0.5)
            }
            .padding(.bottom, 4)

            ForEach(shown, id: \.self) { remote in
                row(remote)
            }

            if device.tabs.count > Self.collapsedCount {
                Button {
                    if isExpanded { expanded.remove(device.id) } else { expanded.insert(device.id) }
                } label: {
                    Text(isExpanded
                         ? String(localized: "Show Less")
                         : String(localized: "Show All (\(device.tabs.count))"))
                        .font(.system(size: 10, design: .serif))
                        .tracking(1)
                        .foregroundColor(Deco.gold)
                        .padding(.top, 4)
                        .padding(.leading, 26)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ remote: TabSync.RemoteTab) -> some View {
        let host = URL(string: remote.url)?.host() ?? ""
        return Button {
            tab.open(bookmark: remote.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "hexagon")
                    .font(.system(size: 10))
                    .foregroundColor(Deco.faintGold)
                    .frame(width: 16)
                Text(verbatim: remote.title)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.gold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(verbatim: host)
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(remote.url)
    }
}
