//
//  PasswordFill.swift
//  Skyscraper
//
//  ログイン欄の見張りと記入。
//
//  仕込む世界を分けてあるのが肝で、注入するスクリプトはページ本来の
//  JS からは見えない専用の WKContentWorld で動く。DOM だけは共有されるので
//  記入はできるが、ページ側から __skyscraperFill を呼んで鍵を引き出したり、
//  こちらのブリッジに偽の送信を流し込んだりはできない。
//
//  記入するのは主フレームだけにしてある。iframe の中の入力欄は、
//  親と違う出所であることが多い（広告・埋め込みウィジェット）。
//  親の資格情報をそこへ流すのは、そのまま漏洩の経路になる。
//

import Foundation
import WebKit

enum PasswordFill {
    static let messageHandlerName = "skyscraperPassword"

    // ページから覗けない専用の世界
    static let world = WKContentWorld.world(name: "SkyscraperPasswords")

    static let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: world
    )

    // 記入を頼む。値は JSON にして渡す（引用符や改行で式が壊れないように）
    static func fillScript(username: String, password: String) -> String? {
        guard let user = jsonString(username), let secret = jsonString(password) else {
            return nil
        }
        return "window.__skyscraperFill(\(user), \(secret));"
    }

    private static func jsonString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return nil }
        // ["..."] の角括弧を外して文字列リテラルだけ取り出す
        return String(array.dropFirst().dropLast())
    }

    private static let source = """
    (() => {
        if (window.__skyscraperPasswordInstalled) { return; }
        window.__skyscraperPasswordInstalled = true;

        const post = (kind, payload) => {
            try {
                window.webkit.messageHandlers.skyscraperPassword.postMessage(
                    Object.assign({ kind: kind }, payload || {})
                );
            } catch (e) { /* ハンドラが無い（世界が違う）時は黙る */ }
        };

        // 人の目に触れている入力欄か。
        // 画面外や 1px の入力欄は、記入させて盗るための罠であることがある
        const visible = (el) => {
            if (!el || el.disabled || el.readOnly) { return false; }
            const rect = el.getBoundingClientRect();
            if (rect.width < 4 || rect.height < 4) { return false; }
            const style = window.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.display === 'none') { return false; }
            if (parseFloat(style.opacity || '1') < 0.05) { return false; }
            return true;
        };

        const passwordFields = () =>
            Array.prototype.slice
                .call(document.querySelectorAll('input[type="password"]'))
                .filter(visible);

        // パスワード欄の相棒になる利用者名の欄。
        // 同じ form の中で、パスワード欄より前にある最も近いものを選ぶ
        const usernameFor = (pw) => {
            const scope = pw.form || document;
            const inputs = Array.prototype.slice.call(scope.querySelectorAll('input'));
            const kinds = ['text', 'email', 'tel', 'url', ''];
            let best = null;
            for (const input of inputs) {
                const type = (input.getAttribute('type') || 'text').toLowerCase();
                if (kinds.indexOf(type) < 0 || !visible(input)) { continue; }
                // pw が input より後ろにあるか
                if (input.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) {
                    best = input;
                }
            }
            return best;
        };

        // React などは value を横取りして変更を追うので、素の代入では気づかれない。
        // プロトタイプ側の setter を直に呼び、入力の合図も自分で投げる
        const setValue = (el, value) => {
            const setter = Object.getOwnPropertyDescriptor(
                HTMLInputElement.prototype, 'value'
            ).set;
            setter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        };

        let sawForm = false;
        let lastShape = '';

        const scan = () => {
            const fields = passwordFields();
            if (!fields.length) { return; }
            sawForm = true;
            lastShape = fields.length + ':' + (usernameFor(fields[0]) ? '1' : '0');
        };

        // 焦点の入った欄がログインの欄か。
        // パスワード欄そのものか、その相棒の利用者名の欄だけを相手にする
        const isLoginField = (el) => {
            if (!el || el.tagName !== 'INPUT') { return false; }
            const fields = passwordFields();
            if (!fields.length) { return false; }
            if (fields.indexOf(el) >= 0) { return true; }
            return usernameFor(fields[0]) === el;
        };

        // 一覧を出す場所。欄の外枠をそのまま Swift へ渡す
        const offerAt = (el) => {
            const rect = el.getBoundingClientRect();
            post('focus', {
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height
            });
        };

        // ページが仕込んだ焦点移動では出さない（isTrusted）。
        // ここを見ないと、目に見えない欄へ勝手に焦点を移して一覧を出させ、
        // 記入を誘う手が通ってしまう
        document.addEventListener('focusin', (event) => {
            if (!event.isTrusted) { return; }
            if (isLoginField(event.target)) {
                offerAt(event.target);
            } else {
                post('dismiss', {});
            }
        }, true);

        document.addEventListener('focusout', (event) => {
            if (isLoginField(event.target)) { post('dismiss', {}); }
        }, true);

        // 欄が動いたら、出しっぱなしの一覧は的外れになる
        window.addEventListener('scroll', () => post('dismiss', {}), true);
        window.addEventListener('resize', () => post('dismiss', {}), true);

        // 送信されたらしい合図を捉えて、打たれた中身を控えに送る。
        // 保存を訊くかどうかは Swift 側が決める
        const report = () => {
            const fields = passwordFields();
            const pw = fields.filter((f) => f.value)[0];
            if (!pw) { return; }
            const user = usernameFor(pw);
            post('submit', {
                username: user ? user.value : '',
                password: pw.value
            });
        };

        document.addEventListener('submit', report, true);

        // form を使わない作り（fetch で送るページ）のための網。
        // Enter と、押せるものへのクリックを見る
        document.addEventListener('keydown', (event) => {
            if (event.key !== 'Enter') { return; }
            const el = event.target;
            if (el && el.tagName === 'INPUT') { report(); }
        }, true);

        document.addEventListener('click', (event) => {
            const el = event.target;
            if (!el || !el.closest) { return; }
            if (el.closest('button, input[type="submit"], input[type="button"], [role="button"]')) {
                // ページが値を消す前に、この場で読む
                report();
            }
        }, true);

        window.addEventListener('pagehide', report, true);

        // 画面遷移せずにログインが済む作りへの備え。
        // 入力欄が消えたら「送信が通った」とみなす合図を送る
        let pending = false;
        const observer = new MutationObserver(() => {
            if (pending) { return; }
            pending = true;
            window.requestAnimationFrame(() => {
                pending = false;
                scan();
                if (sawForm && !passwordFields().length) {
                    sawForm = false;
                    lastShape = '';
                    post('gone', {});
                }
            });
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });

        // Swift から呼ばれる記入口
        window.__skyscraperFill = (username, password) => {
            const fields = passwordFields();
            if (!fields.length) { return false; }
            // 入力欄が二つ以上あるのは新規登録か変更の画面。
            // 古い鍵を勝手に流し込むと、気づかないうちに書き換わる
            if (fields.length > 1) { return false; }
            const pw = fields[0];
            const user = usernameFor(pw);
            if (user && username) { setValue(user, username); }
            setValue(pw, password);
            return true;
        };

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', scan, { once: true });
        } else {
            scan();
        }
    })();
    """
}

// MARK: - 保存を訊ねる時の内訳

enum PasswordPrompt: Equatable {
    // まだ預かっていない組み合わせ
    case save(host: String, username: String)
    // 同じ利用者名で、中身が変わっている
    case update(host: String, username: String)
}

// 送信されたらしい中身。保存を訊くまでの間だけ持つ
struct PasswordCandidate {
    let host: String
    let scheme: String
    let port: Int
    let username: String
    let password: String
}
