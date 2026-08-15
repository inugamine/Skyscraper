//
//  BookmarkSync.swift
//  Skyscraper
//
//  ブックマークを iCloud（CloudKit）で持ち回る。
//
//  置き方は「一件一レコード」ではなく、[Bookmark] を JSON にして
//  一つのレコードに丸ごと入れる。理由は二つある。
//
//  一つ、うちのブックマークは並び順そのものが持ち物だ。一件ずつ
//  レコードに割ると、順番を表す番号を別に持たせて、挿入のたびに
//  周りを振り直す羽目になる。丸ごとなら配列の形がそのまま残る。
//
//  二つ、量が知れている。数百件で数十 KB、CKRecord 一件の上限
//  1MB にはまるで届かない。分ける理由が無い。
//
//  この選び方は後々まで効く。CloudKit は本番へ流した項目を
//  取り消せない（Production のスキーマは一方通行だ）。
//  中身を JSON の塊にしておけば、ブックマークの構造をいくら変えても
//  向こうに見えているのは payload という箱一つのままで済む。
//
//  衝突は後勝ち（last-write-wins）で割り切る。同じ iCloud に
//  繋がった二台が、同じ数秒の間に別々のブックマークを触った時だけ
//  片方が消える。一人で二台を使う分にはまず起きないし、起きても
//  失うのはブックマーク一件だ。
//
//  そのぶん承知しておくべき性質が一つある——**消去も後勝ちで伝わる**。
//  向こうで消した結果が丸ごと降ってくるので、こちらで消したものが
//  復活することは無い代わりに、両方で別々に編集すると新しい方が勝つ。
//
//  知らせ（CKSubscription）は使わない。あれで変更を突っつくには
//  プッシュ通知の仕掛けが要るが、Developer ID 配布だとそこが濁る。
//  ブックマークは秒単位で揃える必要が無いので、
//  「起動した時」「窓が手前に戻った時」に取りに行く形で足りる。
//

import AppKit
import CloudKit
import Foundation
import os

@MainActor
final class BookmarkSync {

    // 設定画面から入り切りする鍵。既定は入り。
    //
    // iCloud に入っていない人の所では、そもそも下の isUsable で
    // 止まって何も起きない。それでも札を出しておくのは、
    // 「入っているが、この Mac では持ち回りたくない」人のためだ
    static let enabledKey = "skyscraper.bookmarks.sync.enabled"

    // 入れ物の名前。ポータルで作ったものと一字一句合っていないと、
    // 実行時に「そんなコンテナは無い」で黙って何も起きない
    private static let containerID = "iCloud.net.live-on.inugamine.Skyscraper"

    // 置き場所。レコードは一件しか作らないので、名前を決め打ちにする。
    // 決め打ちにしておくと「探す」手順が要らず、いつでも直に取れる
    private static let recordType = "BookmarkList"
    private static let recordName = "bookmarks"

    // 記録の出し先。
    //
    // print から替えたのは、あれが配った先で消えるからだ。
    // Xcode から走らせている間は端末に出るので気づかないが、
    // Finder から起動した app の標準出力は誰も見ていない。
    // Logger なら Console.app に残るので、他所の Mac で
    // 何が起きたかを後から聞ける
    private static let log = Logger(subsystem: "net.live-on.inugamine.Skyscraper",
                                    category: "BookmarkSync")

    private let container: CKContainer
    private let database: CKDatabase
    private let recordID = CKRecord.ID(recordName: BookmarkSync.recordName)

    // 持ち主。BookmarkStore がこちらを持つので、こちらは弱く持つ
    private weak var store: BookmarkStore?

    // 直近に触ったレコード。CloudKit は「サーバの版と食い違っていないか」を
    // レコードに埋まった印（recordChangeTag）で見ているので、
    // 一度手にしたものは取っておく。毎回取りに行かずに済む
    private var known: CKRecord?

    // 最後に向こうと揃えた中身。
    //
    // 送る直前にこれと見比べて、同じなら通信そのものを省く。
    // 降ってきた分を流し込むと didSet が回るので、
    // 何もしないと「受け取った直後に、同じ物を送り返す」が起きる。
    // 印（isApplyingRemote）でも止めているが、あれは同じ流れの中でしか
    // 効かない。時間を跨いだ往復——例えば窓を手前に戻すたびに
    // 一度ずつ送り直す類——はこちらで止める
    private var syncedPayload: Data?

    // 降ってきた分を流し込んでいる最中の印
    private var isApplyingRemote = false

    // 送りを遅らせる係と、実際に走っている係。
    //
    // 二つを別々の手綱にしてあるのは、遅らせている間の取り消しと、
    // 走り出した後の取り消しを混ぜないためだ。走っている方を
    // 途中で切ると、保存が半端なところで止まる
    private var debounce: Task<Void, Never>?
    private var running: Task<Void, Never>?

    private var isEnabled: Bool {
        // 一度も触られていない時に false を返させないため、
        // 鍵の有無を見てから読む（UserDefaults の bool は既定が false）
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    init(store: BookmarkStore) {
        self.store = store
        container = CKContainer(identifier: Self.containerID)
        database = container.privateCloudDatabase
    }

    // MARK: - 出入りの合図

    func start() {
        // 窓が手前に戻るたびに取りに行く。起動直後にも一度飛んでくるので、
        // 「起動時に読む」はこれ一本で兼ねられる。
        //
        // 監視を外していないのは、この持ち主がアプリと同じだけ生きるからだ
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pullSoon()
            }
        }
    }

    // 設定で入り切りされた時に呼ぶ。
    // 入れ直した直後は、手元と向こうが食い違っている見込みが高い
    func settingChanged() {
        guard isEnabled else {
            debounce?.cancel()
            Self.log.info("同期を止めた")
            return
        }
        Self.log.info("同期を入れた")
        pullSoon()
    }

    // 変わったので送る。BookmarkStore の didSet から呼ばれる。
    //
    // 三秒待つのは、並べ替えの最中に一手ごとの往復が起きるのを避けるため。
    // ドラッグで五件動かせば配列は五回差し替わるが、送るのは最後の一回でいい
    func scheduleUpload() {
        guard isEnabled, !isApplyingRemote else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.upload()
        }
    }

    private func pullSoon() {
        guard isEnabled, running == nil else { return }
        running = Task { [weak self] in
            await self?.download()
            self?.running = nil
        }
    }

    private func upload() {
        running?.cancel()
        running = Task { [weak self] in
            await self?.push()
            self?.running = nil
        }
    }

    // MARK: - 取りに行く

    private func download() async {
        guard isEnabled, await isUsable, let store else { return }

        do {
            let record = try await database.record(for: recordID)
            known = record
            apply(record)
        } catch let error as CKError where error.code == .unknownItem {
            // まだ誰も置いていない。こちらの分を最初の一つとして上げる。
            // 手ぶらなら上げる意味も無いので、その時は何もしない
            if !store.bookmarks.isEmpty {
                Self.log.info("向こうは空だった。こちらの分を上げる")
                await push()
            }
        } catch {
            report("取り込み", error)
        }
    }

    private func apply(_ record: CKRecord) {
        guard let store,
              let data = record["payload"] as? Data,
              let incoming = try? JSONDecoder().decode([Bookmark].self, from: data)
        else {
            Self.log.error("降ってきた中身を読めなかった")
            return
        }

        // 受け取った時点で「向こうと揃っている」ことになる。
        // 中身が同じで差し替えを見送る場合でも控えるのが要点だ——
        // ここを通さないと、次に窓を手前に戻した時に
        // 同じ物をもう一度送り返してしまう
        syncedPayload = data

        // 中身が同じなら触らない。
        // 差し替えると didSet が回って UserDefaults への書き出しが走るし、
        // 帯も引き直される。同じものを入れ直す理由は無い
        guard incoming != store.bookmarks else {
            Self.log.debug("向こうと同じ内容だった（\(incoming.count) 件）")
            return
        }

        // 流し込んでいる間だけ、送り返す口を閉じる。
        // didSet は同じ流れの中で同期に走るので、直後に開けて構わない
        isApplyingRemote = true
        store.bookmarks = incoming
        isApplyingRemote = false

        Self.log.info("\(incoming.count) 件を取り込んだ")
    }

    // MARK: - 送る

    private func push() async {
        guard isEnabled, await isUsable, let store else { return }
        guard let data = try? JSONEncoder().encode(store.bookmarks) else {
            Self.log.error("ブックマークを JSON にできなかった")
            return
        }

        // 前に揃えた中身と同じなら、通信そのものを省く。
        // 三秒の待ちを抜けてここまで来ても、内容が動いていない場合はある
        //（並べ替えて元の位置に戻した、など）
        guard data != syncedPayload else {
            Self.log.debug("中身が動いていないので送らない")
            return
        }

        let record = known ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["payload"] = data as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        do {
            known = try await database.save(record)
            syncedPayload = data
            Self.log.info("\(store.bookmarks.count) 件を送った")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 向こうが先に書いていた。後勝ちなので、
            // サーバの版を土台にしてこちらの中身で塗り潰す。
            //
            // 土台を貰い直すのは印（recordChangeTag）のためだ。
            // 手元の古い印のまま押し込もうとしても、また同じ理由で弾かれる
            guard let server = error.serverRecord else {
                report("送信", error)
                return
            }
            server["payload"] = data as CKRecordValue
            server["updatedAt"] = Date() as CKRecordValue
            do {
                known = try await database.save(server)
                syncedPayload = data
                Self.log.info("向こうの版を塗り替えて送った（\(store.bookmarks.count) 件）")
            } catch {
                report("送信のやり直し", error)
            }
        } catch {
            report("送信", error)
        }
    }

    // MARK: - 下ごしらえ

    // iCloud に入っていない人も、入っているが iCloud Drive を切っている人も居る。
    // そういう時は黙って何もしない——ブラウザとしての仕事は同期が無くても回るので、
    // 警告を出して邪魔をする筋合いが無い
    private var isUsable: Bool {
        get async {
            do {
                let status = try await container.accountStatus()
                if status != .available {
                    Self.log.debug("iCloud が使えない状態（\(status.rawValue)）")
                }
                return status == .available
            } catch {
                report("iCloud の状態確認", error)
                return false
            }
        }
    }

    // 失敗は記録に落とすだけにする。
    // 通信の失敗は日常茶飯事（機内、圏外、iCloud の一時的な不調）で、
    // そのたびに人の手を止めさせるほどの事ではない。
    //
    // CKError の番号を添えるのは、他所の Mac で何が起きたかを
    // 後から聞き出す時の手掛かりになるからだ
    private func report(_ what: String, _ error: Error) {
        if let ckError = error as? CKError {
            Self.log.error("\(what)に失敗 — CKError \(ckError.errorCode): \(ckError.localizedDescription)")
        } else {
            Self.log.error("\(what)に失敗 — \(error.localizedDescription)")
        }
    }
}
