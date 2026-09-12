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

    // 削除は二段目で入れる。
    // WKWebsiteDataStore.remove(forIdentifier:) は使用中だと失敗するので、
    // そのプロファイルのタブを全窓から閉じてから呼ぶ手順が要る
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
                    }
                }
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
    }
}
