//
//  PasswordListView.swift
//  Skyscraper
//
//  預かっているログイン情報の一覧（設定画面から開く）。
//
//  記入する時は何も訊かないのに、ここで見せる時だけ本人確認を求めるのは、
//  重さの違いによる。記入は今その場の画面に入るだけだが、
//  ここで平文を出すのは覗き見と書き写しに晒すということだ。
//  Safari の「パスワード」も同じ線引きをしている。
//

import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

struct PasswordListView: View {
    @ObservedObject private var store = PasswordStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var logins: [SavedLogin] = []
    // 本人確認を通して見せている一件と、その中身
    @State private var revealed: SavedLogin?
    @State private var revealedPassword = ""
    @State private var confirmingDeleteAll = false
    // 本人確認が通らなかった理由。
    // 黙って何も起きないと、押し間違えたのか壊れているのか分からない
    @State private var authNote: String?
    // 取り込みの結果と、取り込んだファイルの置き場所
    @State private var importNote: String?
    @State private var importedFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.gold)
                Text("Saved Passwords")
                    .font(.system(size: 14, design: .serif))
                    .tracking(3)
                    .foregroundColor(Deco.cream)
                Spacer()
                Text(verbatim: "\(logins.count)")
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(Deco.dimGold)
            }
            .padding(.bottom, 10)

            Zigzag(teeth: 18)
                .stroke(Deco.gold, lineWidth: 1)
                .frame(height: 5)
                .padding(.bottom, 14)

            if logins.isEmpty {
                Text("Nothing is saved yet. Skyscraper asks before it keeps anything.")
                    .font(.system(size: 11, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(logins.enumerated()), id: \.element.id) { index, login in
                            if index > 0 {
                                Rectangle()
                                    .fill(Deco.faintGold.opacity(0.4))
                                    .frame(height: 1)
                            }
                            row(login)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Rectangle().stroke(Deco.faintGold, lineWidth: 1))
            }

            if let authNote {
                note(authNote, symbol: "exclamationmark.triangle")
            }

            if let importNote {
                note(importNote, symbol: "arrow.down.doc")
            }

            // 書き出した CSV は平文のパスワードの束だ。
            // 取り込んだ後も置きっぱなしになりやすいので、その場で片付けられるようにする
            if let file = importedFile {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(Deco.gold)
                    Text("That file holds the passwords in plain text.")
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Deco.dimGold)
                        .fixedSize(horizontal: false, vertical: true)
                    button("Move to Trash") { trash(file) }
                    Spacer()
                }
                .padding(.top, 10)
            }

            HStack(spacing: 12) {
                button("Import…") { chooseFile() }
                if !logins.isEmpty {
                    button("Delete All") { confirmingDeleteAll = true }
                }
                Spacer()
                button("Done") { dismiss() }
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 520, height: 470)
        .background(Deco.ink)
        .preferredColorScheme(.dark)
        .onAppear(perform: reload)
        .onChange(of: store.revision) { _, _ in reload() }
        .confirmationDialog("Delete every saved password?",
                            isPresented: $confirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                store.deleteAll()
                hideRevealed()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed from the keychain and cannot be brought back.")
        }
    }

    // MARK: - 一行

    private func row(_ login: SavedLogin) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: login.origin)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Deco.gold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: login.username.isEmpty
                     ? String(localized: "(no user name)")
                     : login.username)
                    .font(.system(size: 10, design: .serif))
                    .foregroundColor(Deco.dimGold)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if revealed == login {
                Text(verbatim: revealedPassword)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Deco.cream)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .trailing)
                button("Hide") { hideRevealed() }
            } else {
                button("Show") { reveal(login) }
            }

            Button {
                store.delete(login)
                if revealed == login { hideRevealed() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(Deco.dimGold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(verbatim: text)
                .font(.system(size: 10, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundColor(Deco.dimGold)
        .padding(.top, 12)
    }

    private func button(_ title: LocalizedStringKey,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, design: .serif))
                .tracking(1)
                .foregroundColor(Deco.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Hexagon(inset: 4).stroke(Deco.faintGold, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 取り込み

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a CSV exported from Passwords.app or another browser.")

        guard panel.runModal() == .OK, let file = panel.url else { return }

        authNote = nil
        importedFile = nil
        do {
            let result = try PasswordImport.run(from: file)
            importNote = result.skipped == 0
                ? String(localized: "Took in \(result.imported) passwords.")
                : String(localized: "Took in \(result.imported) passwords, skipped \(result.skipped) rows.")
            // 一件も入らなかったなら、片付けを勧める筋合いは無い
            if result.imported > 0 { importedFile = file }
            reload()
        } catch {
            importNote = error.localizedDescription
        }
    }

    private func trash(_ file: URL) {
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
            importedFile = nil
            importNote = String(localized: "The file was moved to the Trash.")
        } catch {
            importNote = error.localizedDescription
        }
    }

    // MARK: - 中身

    private func reload() {
        logins = store.allLogins()
        // 消された一件を出したままにしない
        if let shown = revealed, !logins.contains(shown) { hideRevealed() }
    }

    private func hideRevealed() {
        revealed = nil
        revealedPassword = ""
    }

    // Touch ID か、無ければアカウントのパスワードで本人確認する。
    // 端末が生体認証を持たない場合も deviceOwnerAuthentication なら通る
    private func reveal(_ login: SavedLogin) {
        authNote = nil

        let context = LAContext()
        let reason = String(localized: "show the saved password")
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 本人確認の手立てが無い機械では、確かめようがないので見せない。
            // 「確かめられないから素通し」にすると、席を外した隙が穴になる。
            //
            // ここで一番多いのは、署名されていないビルドで動かしている場合。
            // LocalAuthentication は署名の無いアプリを相手にしない
            print("PasswordListView: authentication unavailable — \(String(describing: error))")
            authNote = String(localized: "Cannot verify who you are, so the password is not shown.")
                + " (" + (error?.localizedDescription ?? "—") + ")"
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            Task { @MainActor in
                guard ok else {
                    print("PasswordListView: authentication refused — \(String(describing: error))")
                    // 本人が取り消した時に小言を出さない
                    if (error as? LAError)?.code != .userCancel {
                        authNote = error?.localizedDescription
                    }
                    return
                }
                guard let password = store.password(for: login) else {
                    authNote = String(localized: "The keychain did not return the password.")
                    return
                }
                revealedPassword = password
                revealed = login
            }
        }
    }
}
