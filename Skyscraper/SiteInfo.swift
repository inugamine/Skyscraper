//
//  SiteInfo.swift
//  Skyscraper
//
//  アドレスバー左端の鍵と、そこから垂れるサイトの調書。
//
//  今まで、接続が暗号化されているかどうかを知る手立てが一つも無かった。
//  アドレスの綴りを目で追えば分かる、というのは建前で、綴りは長いし、
//  リダイレクトで静かに http へ落ちても誰も気付かない。
//
//  もう一つ、この盤は各所に散らばった「このサイトについて覚えていること」の
//  出口でもある。カメラの許可、ポップアップの許可、パスワードを訊かない印——
//  預けた先はそれぞれ別の Store だが、利用者から見れば全部
//  「このサイトに許したこと」だ。今までは設定画面の全消ししか道が無く、
//  一枚のために他のサイトの分まで巻き添えにするしかなかった。
//

import SwiftUI
import WebKit

// MARK: - 接続の格

enum SiteSecurity: Equatable {
    case none       // ロビーや about: ——出すものが無い
    case local      // file://
    case secure     // https、検証も通った
    case exception  // https だが、証明書の例外を通してある
    case insecure   // http

    // 鍵そのものを出すか。ロビーで鍵が光っていても意味が無い
    var isShown: Bool { self != .none }

    var symbol: String {
        switch self {
        case .none:      return "circle"
        case .local:     return "folder"
        case .secure:    return "lock"
        case .exception: return "lock.trianglebadge.exclamationmark"
        case .insecure:  return "lock.open"
        }
    }

    var tint: Color {
        switch self {
        case .none, .local:      return Deco.dimGold
        case .secure:            return Deco.gold
        case .exception,
             .insecure:          return Deco.rust
        }
    }

    var headline: LocalizedStringKey {
        switch self {
        case .none:      return "Nothing is loaded"
        case .local:     return "This is a file on this Mac"
        case .secure:    return "The connection is encrypted"
        case .exception: return "The certificate is not trusted"
        case .insecure:  return "The connection is not encrypted"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .none:
            return "Open a page to see how it is connected."
        case .local:
            return "It was opened from the disk, so nothing travelled over the network."
        case .secure:
            return "The server proved its identity, and what passes between you cannot be read on the way."
        case .exception:
            return "You chose to continue past a certificate this Mac does not trust. Skyscraper will forget this when you quit."
        case .insecure:
            return "Anything you type on this page — including passwords — travels in the clear."
        }
    }
}

// MARK: - このサイトに許したこと、一行ぶん

struct SitePermission: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let state: LocalizedStringKey
    // 取り消しの札に出す言葉（許可の性質で言い回しが変わる）
    let clearTitle: LocalizedStringKey
    let clear: @MainActor () -> Void
}

// MARK: - 調書の盤

struct SiteInfoPopover: View {
    @ObservedObject var tab: Tab
    // 例外の増減を盤に届ける。
    // ここで取り消した直後に、見出しの鍵も変わらないと嘘になる
    @ObservedObject private var exceptions = CertificateExceptionStore.shared
    // 証明書の窓（シート）を出す時に、この盤を先に畳むために持つ
    @Binding var isPresented: Bool

    // 覚えていることの一覧。取り消すたびに組み直す
    @State private var permissions: [SitePermission] = []
    @State private var isClearingData = false
    @State private var clearedData = false

    private var url: URL? { URL(string: tab.urlText) }
    private var host: String { url?.host() ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            connection
            permissionSection
            // 保存されたデータの話は、相手がサーバの時だけだ。
            // 手元のファイルやロビーに「このサイトのデータ」は無い
            if !host.isEmpty {
                dataSection
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 300)
        .background(Deco.panel)
        .onAppear(perform: rebuild)
    }

    // ══════════════════════════════════════════════
    //  見出し
    // ══════════════════════════════════════════════

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: tab.security.symbol)
                    .font(.system(size: 12))
                    .foregroundColor(tab.security.tint)

                Text(verbatim: host.isEmpty ? tab.urlText : host)
                    .font(.system(size: 13, design: .serif))
                    .tracking(1)
                    .foregroundColor(Deco.cream)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.bottom, 10)

            Zigzag(teeth: 16)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.bottom, 14)
        }
    }

    // ══════════════════════════════════════════════
    //  接続の格
    // ══════════════════════════════════════════════

    private var connection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tab.security.headline)
                .font(.system(size: 12, design: .serif))
                .foregroundColor(Deco.cream)
                .fixedSize(horizontal: false, vertical: true)

            Text(tab.security.detail)
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // 証明書は https の時だけ手に入る
            if tab.security == .secure || tab.security == .exception {
                chipButton("View Certificate") {
                    // 盤を先に畳む。ポップオーバーを出したまま
                    // シートを垂らすと、二枚が重なって見づらい
                    let site = host
                    isPresented = false
                    // SecTrust はこの中で取る。
                    // 外で取って渡すと Sendable でない値が
                    // Task の境を跨ぐことになる
                    Task { @MainActor in
                        await CertificateExceptionStore.shared
                            .show(host: site,
                                  trust: tab.serverTrust(for: site),
                                  in: tab.webView.window)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 18)
    }

    // ══════════════════════════════════════════════
    //  このサイトに許したこと
    // ══════════════════════════════════════════════

    @ViewBuilder
    private var permissionSection: some View {
        sectionHeader("Permissions")

        if permissions.isEmpty {
            Text("Skyscraper remembers nothing about this site.")
                .font(.system(size: 10, design: .serif))
                .foregroundColor(Deco.dimGold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(permissions) { permission in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.label)
                                .font(.system(size: 11, design: .serif))
                                .foregroundColor(Deco.cream)
                            Text(permission.state)
                                .font(.system(size: 9, design: .serif))
                                .foregroundColor(Deco.dimGold)
                        }

                        Spacer(minLength: 0)

                        chipButton(permission.clearTitle) {
                            permission.clear()
                            rebuild()
                        }
                    }
                }
            }
            .padding(.bottom, 18)
        }
    }

    // ══════════════════════════════════════════════
    //  このサイトのデータ
    // ══════════════════════════════════════════════

    @ViewBuilder
    private var dataSection: some View {
        sectionHeader("Stored Data")

        Text("Cookies, caches and local storage kept for this site. Sign-ins here will end.")
            .font(.system(size: 10, design: .serif))
            .foregroundColor(Deco.dimGold)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)

        HStack(spacing: 10) {
            chipButton("Clear Data for This Site") {
                Task { await clearSiteData() }
            }
            .disabled(isClearingData || host.isEmpty)

            if isClearingData {
                ProgressView()
                    .controlSize(.small)
                    .tint(Deco.gold)
            } else if clearedData {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text("Cleared")
                        .font(.system(size: 10, design: .serif))
                }
                .foregroundColor(Deco.gold)
            }
        }
    }

    // ══════════════════════════════════════════════
    //  部品
    // ══════════════════════════════════════════════

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, design: .serif))
                .tracking(2)
                .foregroundColor(Deco.gold)
                .padding(.bottom, 6)

            Zigzag(teeth: 12)
                .stroke(Deco.faintGold, lineWidth: 1)
                .frame(height: 4)
                .padding(.bottom, 10)
        }
    }

    private func chipButton(_ title: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.gold)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // ══════════════════════════════════════════════
    //  中身の組み立て
    // ══════════════════════════════════════════════

    // 散らばった Store を順に当たって、このサイトの分だけ拾う
    private func rebuild() {
        // 前回の「削除しました」を引きずらない
        clearedData = false

        let site = host
        guard let url else {
            permissions = []
            return
        }
        var list: [SitePermission] = []

        // ── カメラ・マイク ──
        //
        // 鍵は scheme://host[:port]。host を持たない場所（file: など）は
        // そもそも許可を訊かれないので、空なら見に行かない
        let origin = MediaPermissionStore.storageOrigin(for: url)
        if !origin.isEmpty {
            for device in ["camera", "microphone"] {
                guard let allowed = MediaPermissionStore.shared.decision(origin: origin,
                                                                         device: device)
                else { continue }
                list.append(SitePermission(
                    id: "media.\(device)",
                    label: device == "camera" ? "Camera" : "Microphone",
                    state: allowed ? "Allowed" : "Blocked",
                    clearTitle: "Forget",
                    clear: { MediaPermissionStore.shared.forget(origin: origin, device: device) }
                ))
            }
        }

        // ── ポップアップ ──
        //
        // こちらは file: にも鍵がある。PopupAllowList が、host を
        // 持たない場所にはスキームとパスから代わりの鍵を組む
        let popupKey = PopupAllowList.originKey(for: url)
        if PopupAllowList.shared.isAllowed(popupKey) {
            list.append(SitePermission(
                id: "popup",
                label: "Pop-up windows",
                state: "Allowed",
                clearTitle: "Revoke",
                clear: { PopupAllowList.shared.revoke(popupKey) }
            ))
        }

        // ── パスワードの問い ──
        if !site.isEmpty, PasswordNeverList.shared.contains(site) {
            list.append(SitePermission(
                id: "password",
                label: "Saving passwords",
                state: "Never asked here",
                clearTitle: "Ask Again",
                clear: { PasswordNeverList.shared.remove(site) }
            ))
        }

        // ── 証明書の例外（この起動の間だけ）──
        let port = url.port ?? 443
        if !site.isEmpty, CertificateExceptionStore.shared.hasException(host: site, port: port) {
            list.append(SitePermission(
                id: "certificate",
                label: "Untrusted certificate",
                state: "Accepted for this session",
                clearTitle: "Revoke",
                clear: { CertificateExceptionStore.shared.forget(host: site, port: port) }
            ))
        }

        permissions = list
    }

    // このサイトの分だけ消す。
    //
    // WKWebsiteDataStore は登録可能ドメイン単位で束ねて持っている
    //（www.example.com も docs.example.com も "example.com" 一枚）。
    // だから完全一致だけでは当たらないことがあり、末尾でも照合する
    private func clearSiteData() async {
        let target = host.lowercased()
        guard !target.isEmpty else { return }

        isClearingData = true
        clearedData = false
        defer { isClearingData = false }

        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matched = records.filter { record in
            let name = record.displayName.lowercased()
            guard !name.isEmpty else { return false }
            return target == name || target.hasSuffix("." + name)
        }
        guard !matched.isEmpty else {
            clearedData = true
            return
        }
        await store.removeData(ofTypes: types, for: matched)
        clearedData = true
    }
}

// MARK: - アドレスバーの鍵

struct SiteSecurityButton: View {
    @ObservedObject var tab: Tab
    // 例外の増減を鍵の色へ届ける。
    // 番地を変えずに例外が消える道がある以上
    //（盤の「取り消す」と、設定画面の一括消し）、
    // tab だけ見張っていても鍵は古いままになる
    @ObservedObject private var exceptions = CertificateExceptionStore.shared
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: tab.security.symbol)
                .font(.system(size: 11))
                .foregroundColor(tab.security.tint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tab.security.isShown)
        // ロビーでは鍵を消すが、場所は空けたままにする。
        // 引っ込めると、タブを移るたびに欄の左端が横へ跳ねる
        .opacity(tab.security.isShown ? 1 : 0)
        .help("Site Information")
        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
            SiteInfoPopover(tab: tab, isPresented: $showingInfo)
        }
    }
}
