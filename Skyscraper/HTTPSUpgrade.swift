//
//  HTTPSUpgrade.swift
//  Skyscraper
//
//  http:// と書かれた行き先を、まず https:// で叩いてみる係。
//
//  今どき平文で喋る必要のあるサイトはほとんど無い。にもかかわらず、
//  古いリンクや手打ちの綴りには http:// が残り続けている。そのまま繋ぐと、
//  同じ回線に居る誰かに中身を読まれるし、書き換えられても気付けない。
//  先に https を試せば、対応しているサーバならそれで済む——大半はそうだ。
//
//  ただし「黙って持ち上げて、駄目なら黙って落とす」のは筋が悪い。
//  それでは利用者は、自分が平文で喋っていることを最後まで知らない。
//  なので落ちた時だけ確認を挟む。作法は CertificateTrust.swift と同じだ。
//  ・既定のボタンは「戻る」。Return を叩いただけで平文にならない
//  ・進む方は destructive の見た目にして、押す気が要る形にする
//  ・一度通した場所は控えるが、控えはメモリだけ。アプリを終えば消える
//
//  持ち上げない相手も決めてある。手元の開発サーバや宅内の機械は
//  そもそも TLS を立てていないことが多く、毎回 443 を殴りに行っても
//  待たされるだけで何の得も無い（下の isExempt を見ろ）。
//

import AppKit
import Combine
import Foundation

@MainActor
final class HTTPSFirstStore: ObservableObject {
    static let shared = HTTPSFirstStore()

    // 設定画面のトグルと共有する鍵。既定は「持ち上げる」
    static let enabledKey = "skyscraper.httpsFirst"

    // https では繋がらないと分かった場所（"host:port"）。
    //
    // UserDefaults にも書かない。アプリを終えば消える——
    // 証明書の例外と同じ考え方だ。「一度落としたら以後ずっと平文」は、
    // その場限りの障害と、本当に http しか喋らないサーバを
    // 区別しないまま固定してしまう
    @Published private var plainAllowed: Set<String> = []

    private init() {}

    var isEnabled: Bool {
        // @AppStorage の既定値と揃える。鍵が無い＝まだ触られていない
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var isEmpty: Bool { plainAllowed.isEmpty }

    // 平文のまま通すことにした場所の一覧（設定画面の表示用）
    var places: [String] { plainAllowed.sorted() }

    private static func key(_ url: URL) -> String {
        "\(url.host()?.lowercased() ?? ""):\(url.port ?? 80)"
    }

    // MARK: - 持ち上げるかどうか

    // この行き先を https に持ち上げるか。
    //
    // 判断はここ一箇所に閉じ込める。呼ぶ側（Tab の decidePolicyFor）に
    // 条件を散らすと、除外を足した時にどこかが取り残される
    func shouldUpgrade(_ url: URL) -> Bool {
        guard isEnabled,
              url.scheme?.lowercased() == "http",
              let host = url.host(), !host.isEmpty,
              !Self.isExempt(host: host),
              !plainAllowed.contains(Self.key(url))
        else { return false }
        return true
    }

    // 持ち上げた先。
    //
    // ポートは書かれた通りに引き継ぐ。http://例:8080 を 443 に付け替えると
    // 全く別の窓口を叩くことになる。落とすのは 80 の時だけだ——
    // あれは「http の既定」という意味しか持たないので、
    // https に持ち上げた時点で 443 に読み替わるのが正しい
    static func upgraded(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.scheme = "https"
        if comps.port == 80 { comps.port = nil }
        return comps.url
    }

    // 持ち上げない相手。
    //
    // 手元と宅内。この辺りは自己署名すら立てていない機械がほとんどで、
    // 443 を叩いても拒否されるか、黙って呑まれて待たされるだけだ。
    // そして経路が外へ出ないので、平文であることの危険も小さい
    static func isExempt(host: String) -> Bool {
        let name = host.lowercased()

        // ループバックと、名前解決を宅内で済ませる類の綴り
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if name.hasSuffix(".local") { return true }
        if name == "::1" || name == "[::1]" { return true }

        // IPv4 の私設帯とループバック、リンクローカル。
        // 綴りが数字四つでなければ下の判定は素通りする
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]),
              Int(parts[2]) != nil, Int(parts[3]) != nil
        else { return false }

        switch a {
        case 127:  return true               // ループバック
        case 10:   return true               // 私設帯
        case 192:  return b == 168           // 私設帯
        case 172:  return (16...31).contains(b)  // 私設帯
        case 169:  return b == 254           // リンクローカル
        default:   return false
        }
    }

    // MARK: - 控え

    func allowPlain(_ url: URL) {
        guard let host = url.host(), !host.isEmpty else { return }
        plainAllowed.insert(Self.key(url))
    }

    func reset() {
        guard !plainAllowed.isEmpty else { return }
        plainAllowed.removeAll()
    }

    // MARK: - 落とす前の確認

    // https で駄目だった。平文のまま続けるかを訊く。
    //
    // 何が起きたかを先に言う——利用者は https を頼んだ覚えが無い。
    // こちらが勝手に持ち上げて勝手に転んだので、
    // 「証明書が変です」ではなく「安全な方で繋がらなかった」と書く
    func confirmFallback(to url: URL, in window: NSWindow?) async -> Bool {
        let host = url.host() ?? url.absoluteString

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "“\(host)” did not answer over a secure connection")
        alert.informativeText = [
            String(localized: "Skyscraper tried https first, and could not get through."),
            String(localized: "If you continue, this page will travel in the clear. Anyone between you and the server can read it, and change it on the way. Skyscraper will stop trying https for this server until you quit."),
        ].joined(separator: "\n\n")

        let back    = alert.addButton(withTitle: String(localized: "Go Back"))
        let proceed = alert.addButton(withTitle: String(localized: "Continue Without Encryption"))
        back.keyEquivalent = "\r"
        proceed.keyEquivalent = ""
        proceed.hasDestructiveAction = true

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }

        // 一番目が「戻る」なので、二番目を押された時だけ落とす
        return response == .alertSecondButtonReturn
    }
}
