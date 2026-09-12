//
//  Profile.swift
//  Skyscraper
//
//  プロファイル（データの置き場の分離）。
//
//  ── 何が分かれて、何が分かれないか ──
//  WKWebsiteDataStore(forIdentifier:) は Cookie・localStorage・
//  IndexedDB・キャッシュを、識別子ごとに別のディスク領域へ置く。
//  同じサイトに別のアカウントで同時にログインできるのはこのおかげだ。
//
//  分かれないもの：
//  ・拡張機能の状態（browser.storage）。あれは WKWebExtensionController が
//    持っていて、管理役は全窓で一つを共有している
//  ・パスワードとパスキー。macOS のキーチェーン側にあるので割れない。
//    Safari も割っていない
//  ・ブックマーク・履歴・設定。ブラウザ全体のものだ
//
//  ── 誰が持つか ──
//  プロファイルはタブの属性だ。グループ（TabGrouper）の属性ではない。
//  websiteDataStore は WKWebView の生成時に焼き付くので後から変えられず、
//  グループは LLM が付けた名前の対応表に過ぎない（再生成で消える）。
//  タブが profileID を持ち、それに合う置き場で器を作る——それだけだ。
//
//  ── 名前は自前で持つ ──
//  WebKit は識別子（UUID）の一覧こそ返す（fetchAllDataStoreIdentifiers）が、
//  名前は付けられない。名前 ↔ UUID の対応は UserDefaults に置く。
//  UUID を失えばその置き場は二度と開けなくなるので、
//  この対応表は「削除」以外の理由で消してはならない。
//

import Foundation
import SwiftUI
import Combine
import WebKit

// MARK: - 記憶の射程

// サイトごとの記憶（許可・例外・「訊かない」）を、誰の分として持つか。
//
// ストア側は鍵の前置きで割るだけで、中身の構造は変えない。
// 既定は素のオリジンを鍵にするので、今までの保存はそのまま読める（移行は無い）。
// プロファイルを消す時は、その前置きを持つ鍵を全部捨てればいい
// （二段目で入れる）。
//
// 以前は `persistent: Bool` で「プライベートか否か」だけを渡していた。
// プロファイルが増えて二値では足りなくなったので、同じ口をこの型に広げた
enum DataScope: Hashable {
    case `default`          // 普通の窓、プロファイル無し。鍵は素のオリジン
    case profile(UUID)      // プロファイル。鍵に印を前置きする
    case session            // プライベート。メモリだけで、最後の一枚を閉じた時に捨てる

    // ディスクに書くか。プライベートだけが書かない
    var isPersistent: Bool { self != .session }

    // 保存用の鍵。
    // プライベートはメモリの辞書を別に持つので、鍵は既定と同じ形でいい
    // （通常で許したサイトはプライベートでも許す——その照合に同じ鍵が要る）
    func key(_ origin: String) -> String {
        switch self {
        case .default, .session:  return origin
        case .profile(let id):    return Self.prefix(for: id) + origin
        }
    }

    static func prefix(for id: UUID) -> String {
        "profile:" + id.uuidString + "|"
    }
}

struct BrowserProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
}

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    // 並び順は作った順。表示もメニューもこの順で出す
    @Published private(set) var profiles: [BrowserProfile] {
        didSet { save() }
    }

    // 一度開いた置き場は使い回す。
    //
    // forIdentifier: が同じ id で同じ実体を返すかは保証を見付けられなかった。
    // 別の実体が返っても中身（ディスク）は同じはずだが、
    // 「タブごとに別の実体」は PrivateBrowsing で懲りた話なので、
    // こちらで一つに束ねておく
    private var stores: [UUID: WKWebsiteDataStore] = [:]

    private let key = "skyscraper.profiles.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([BrowserProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // ── 引く ──

    func profile(_ id: UUID) -> BrowserProfile? {
        profiles.first { $0.id == id }
    }

    func name(of id: UUID) -> String? {
        profile(id)?.name
    }

    // その id のプロファイルが今も居るか。
    // セッション復元で、消えたプロファイルの id を掴んだタブを既定へ倒すのに使う
    func contains(_ id: UUID) -> Bool {
        profile(id) != nil
    }

    // 置き場を出す。無ければ作る（ディスク上の領域もこの時に生まれる）
    func dataStore(for id: UUID) -> WKWebsiteDataStore {
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = store
        return store
    }

    // ── 増やす・改める ──

    @discardableResult
    func add(name: String) -> BrowserProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let profile = BrowserProfile(id: UUID(), name: trimmed)
        profiles.append(profile)
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
    }

    // ── 消す ──

    // 消し残した置き場の控え。次の起動で片付ける
    private let pendingKey = "skyscraper.profiles.pendingRemoval.v1"

    private var pendingRemovals: [UUID] {
        get {
            (UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: pendingKey)
            } else {
                UserDefaults.standard.set(newValue.map(\.uuidString), forKey: pendingKey)
            }
        }
    }

    // プロファイルを消す。成功すれば nil、転べば読める一行を返す。
    //
    // 中身はその場で空にするが、ディスクの領域そのものは次の起動で消す。
    //
    // WKWebsiteDataStore.remove(forIdentifier:) は「使用中」だと断る。
    // タブを閉じた直後は UI 側の実体がしばらく解けず、それが解けても
    // 今度はネットワークプロセスがセッションを抱えたままになる（実測：
    // "Data store is in use" → "(by network process)" と変わったまま四秒粘っても通らない）。
    // そこに粘るのは筋が悪い。removeData は使用中でも通るので、中身はここで空にする。
    // 利用者から見ればそれで終わりだ。空の箱は次の起動、WebView が生まれる前に消す。
    // Safari も置き場の後始末は起動時にやっている
    func remove(_ id: UUID) async -> String? {
        guard contains(id) else { return nil }

        // 1. 全窓からそのプロファイルのタブを閉じる
        TabManager.closeTabsEverywhere(inProfile: id)

        // 2. 各ストアの記憶（鍵に印の付いた分）を捨てる
        GeolocationStore.shared.forgetProfile(id)
        MediaPermissionStore.shared.forgetProfile(id)
        HTTPSFirstStore.shared.forgetProfile(id)
        CertificateExceptionStore.shared.forgetProfile(id)
        PopupAllowList.shared.forgetProfile(id)
        PasswordNeverList.shared.forgetProfile(id)

        // 3. 中身を空にする。Cookie もストレージもキャッシュも、この時点で消える
        let store = dataStore(for: id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               modifiedSince: .distantPast)
        stores[id] = nil

        // 4. 名簿から消す。後は空の箱の話だから、利用者を待たせない
        profiles.removeAll { $0.id == id }

        // 5. 箱も消せるなら消す。駄目なら控えて、次の起動に回す
        if await tryRemoveDirectory(id, attempts: 3) {
            print("ProfileStore: removed data store \(id)")
        } else {
            var pending = pendingRemovals
            if !pending.contains(id) { pending.append(id) }
            pendingRemovals = pending
            print("ProfileStore: data store \(id) still in use; will remove on next launch")
        }
        return nil
    }

    // ディスクの領域を消す。間を置いて何度か叩き、通ったら true
    private func tryRemoveDirectory(_ id: UUID, attempts: Int) async -> Bool {
        for attempt in 1...max(attempts, 1) {
            try? await Task.sleep(for: .milliseconds(500))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return true
            } catch {
                print("ProfileStore: remove attempt \(attempt) for \(id) failed: \(error)")
            }
        }
        return false
    }

    // 前回消し残した箱を片付ける。起動直後に呼ぶ（SkyscraperApp.init）。
    //
    // 控えにあるものだけでなく、WebKit に識別子付きの置き場を全部出させて、
    // 名簿に居ないものは全部消す。控えを残す前に転んだ孤児（作りかけで落ちた、
    // 古い版が控えずにあきらめた）もこれで拾える。
    //
    // この時点では名簿に無い識別子を使うタブは一つも無い（復元も既定へ倒す）ので、
    // 使用中で断られる理由が無い。それでも転んだら控えに残して、次でまた試す
    func purgePendingRemovals() async {
        let known = Set(profiles.map(\.id))
        let onDisk = (try? await WKWebsiteDataStore.allDataStoreIdentifiers) ?? []
        let orphans = onDisk.filter { !known.contains($0) }
        let targets = Array(Set(pendingRemovals + orphans))
        guard !targets.isEmpty else { return }

        var remaining: [UUID] = []
        for id in targets {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                print("ProfileStore: purged leftover data store \(id)")
            } catch {
                print("ProfileStore: could not purge \(id): \(error)")
                remaining.append(id)
            }
        }
        pendingRemovals = remaining
    }
}

// MARK: - 設定の欄

// 設定 > 一般 > Profiles の中身。
// 見出し（sectionHeader）は SettingsView 側が付けるので、ここは一覧と追加だけ
struct ProfileSettingsSection: View {
    @ObservedObject private var store = ProfileStore.shared

    @State private var showingAdd = false
    @State private var newName = ""
    // 改名中のプロファイル。nil なら何も開いていない
    @State private var renaming: BrowserProfile?
    @State private var renameText = ""
    // 削除を確かめているプロファイル
    @State private var deleting: BrowserProfile?
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.profiles.isEmpty {
                Text("No profiles yet. Each profile keeps its own cookies and site data, so you can be signed in to the same site as two different people.")
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: "person")
                            .font(.system(size: 10))
                            .foregroundColor(Deco.gold)
                        Text(verbatim: profile.name)
                            .font(.system(size: 12, design: .serif))
                            .foregroundColor(Deco.cream)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            renameText = profile.name
                            renaming = profile
                        } label: {
                            Text("Rename")
                                .font(.system(size: 10, design: .serif))
                                .tracking(1)
                                .foregroundColor(Deco.gold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        Button {
                            deleting = profile
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(Deco.dimGold)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    }
                }
            }

            if let deleteError {
                Text(verbatim: deleteError)
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                newName = ""
                showingAdd = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10))
                    Text("Add Profile…")
                        .font(.system(size: 11, design: .serif))
                        .tracking(1)
                }
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(Hexagon(inset: 6).stroke(Deco.faintGold, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .alert("New Profile", isPresented: $showingAdd) {
            TextField("Profile name", text: $newName)
            Button("Create") { store.add(name: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Profile", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Profile name", text: $renameText)
            Button("Rename") {
                if let renaming { store.rename(renaming.id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        // 削除の確認。タブもデータも消えるので、一度は訊く
        .confirmationDialog(
            deleting.map { Text("Delete the profile “\($0.name)”?") } ?? Text(""),
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = deleting {
                Button("Delete Profile", role: .destructive) {
                    isDeleting = true
                    deleteError = nil
                    Task { @MainActor in
                        deleteError = await store.remove(target.id)
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("Its tabs will be closed, and its cookies, site data and permissions will be erased. Bookmarks and saved passwords are shared, so they stay.")
        }
    }
}
