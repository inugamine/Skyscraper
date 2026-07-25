//
//  PasskeyManager.swift
//  Skyscraper
//
//  パスキー（WebAuthn）の橋渡し。
//
//  WKWebView の WebAuthn は自社ドメイン（Associated Domains）限定で、
//  汎用ブラウザとして任意サイトのパスキーを扱うには
//  com.apple.developer.web-browser.public-key-credential エンタイトルメント
//  （Apple への申請制。Chrome / Firefox もこれ）が必要になる。
//
//  仕組みは Chromium と同じ横取り型：
//  1. ページに注入した JS が navigator.credentials.create / get を差し替える
//  2. publicKey 要求だけを skyscraperPasskey ハンドラ（返信付き）へ流す
//  3. Swift 側が ASAuthorizationController で OS のパスキーシートを出す
//  4. 結果（attestation / assertion）を base64url で JS へ返し、
//     JS が PublicKeyCredential 形の応答に組み直してページへ渡す
//
//  origin は ASPublicKeyCredentialClientData(challenge:origin:) に渡す。
//  clientDataJSON の生成は OS 側の仕事なので、こちらで JSON は組まない。
//
//  エンタイトルメント未取得の間は、要求が AuthorizationError 1004 で落ちて
//  ページには NotAllowedError が返る（＝黙って壊れず、綺麗に断られる）。
//

import Foundation
import AppKit
import WebKit
import AuthenticationServices

// MARK: - base64url

extension Data {
    // WebAuthn の世界は全て base64url（パディング無し）で受け渡す
    init?(base64URL: String) {
        var s = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - JS へ返すエラー

// "名前|文言" の形で返し、polyfill 側が DOMException に組み直す
private enum PasskeyError {
    case security(String)
    case notAllowed(String)
    case invalidState(String)
    case notSupported(String)

    var jsMessage: String {
        switch self {
        case .security(let m):     return "SecurityError|" + m
        case .notAllowed(let m):   return "NotAllowedError|" + m
        case .invalidState(let m): return "InvalidStateError|" + m
        case .notSupported(let m): return "NotSupportedError|" + m
        }
    }
}

// MARK: - 橋渡し役本体

@MainActor
final class PasskeyBridge: NSObject {
    static let messageHandlerName = "skyscraperPasskey"

    weak var webView: WKWebView?

    // 進行中の要求。パスキーのシートは一度に一枚
    private var pendingReply: ((Any?, String?) -> Void)?
    private var controller: ASAuthorizationController?

    // MARK: 要求の受け付け

    fileprivate func handle(body: [String: Any],
                            frame: WKFrameInfo,
                            reply: @escaping (Any?, String?) -> Void) {
        guard pendingReply == nil else {
            reply(nil, PasskeyError.notAllowed("Another passkey request is already in progress.").jsMessage)
            return
        }
        guard let op = body["op"] as? String else {
            reply(nil, PasskeyError.notAllowed("Malformed passkey request.").jsMessage)
            return
        }

        // origin はメッセージを送ってきたフレームから取る（JS の自己申告は信じない）
        let origin = frame.securityOrigin
        let scheme = origin.protocol.lowercased()
        let host = origin.host.lowercased()
        guard scheme == "https" || host == "localhost" || host == "127.0.0.1" else {
            reply(nil, PasskeyError.security("Passkeys require a secure context.").jsMessage)
            return
        }
        var originString = "\(scheme)://\(host)"
        let defaultPort = scheme == "https" ? 443 : 80
        if origin.port != 0 && origin.port != defaultPort {
            originString += ":\(origin.port)"
        }

        // RP ID の検証：host そのもの、または host の登録可能な上位ドメインのみ。
        // （厳密には Public Suffix List が要るが、"." を含む上位一致で近似する）
        let rpId = ((body["rp"] as? [String: Any])?["id"] as? String)
            ?? (body["rpId"] as? String)
            ?? host
        let rpOK = rpId == host
            || (host.hasSuffix("." + rpId) && rpId.contains("."))
            || (rpId == "localhost" && host == "localhost")
        guard rpOK else {
            reply(nil, PasskeyError.security("The relying party ID is not a registrable domain suffix of the origin.").jsMessage)
            return
        }

        // プラットフォームパスキーへのアクセス許可（初回はOSが確認を出す）を
        // 済ませてから本番の要求へ進む
        pendingReply = reply
        ensureAuthorization { [weak self] in
            guard let self else { return }
            do {
                let requests: [ASAuthorizationRequest]
                switch op {
                case "create":
                    requests = try self.buildRegistrationRequests(body: body, rpId: rpId, origin: originString)
                case "get":
                    requests = try self.buildAssertionRequests(body: body, rpId: rpId, origin: originString)
                default:
                    throw PasskeyBridgeFailure(PasskeyError.notAllowed("Unknown operation."))
                }
                let controller = ASAuthorizationController(authorizationRequests: requests)
                controller.delegate = self
                controller.presentationContextProvider = self
                self.controller = controller
                controller.performRequests()
            } catch let failure as PasskeyBridgeFailure {
                self.finish(nil, failure.error.jsMessage)
            } catch {
                self.finish(nil, PasskeyError.notAllowed(error.localizedDescription).jsMessage)
            }
        }
    }

    // パスキー利用の事前許可。未確認なら OS のダイアログを出して待つ。
    // 断られていてもセキュリティキーが通る余地はあるので、結果に関わらず進む
    private func ensureAuthorization(_ run: @escaping () -> Void) {
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        switch manager.authorizationStateForPlatformCredentials {
        case .notDetermined:
            manager.requestAuthorizationForPublicKeyCredentials { _ in
                Task { @MainActor in run() }
            }
        default:
            run()
        }
    }

    // MARK: 登録（navigator.credentials.create）

    private func buildRegistrationRequests(body: [String: Any],
                                           rpId: String,
                                           origin: String) throws -> [ASAuthorizationRequest] {
        guard let challengeB64 = body["challenge"] as? String,
              let challenge = Data(base64URL: challengeB64),
              let user = body["user"] as? [String: Any],
              let userIDB64 = user["id"] as? String,
              let userID = Data(base64URL: userIDB64) else {
            throw PasskeyBridgeFailure(.notAllowed("Malformed registration options."))
        }
        let name = (user["name"] as? String) ?? ""
        let displayName = (user["displayName"] as? String) ?? name
        let selection = body["authenticatorSelection"] as? [String: Any] ?? [:]
        let attachment = selection["authenticatorAttachment"] as? String
        let uv = userVerification(selection["userVerification"] as? String)

        let clientData = ASPublicKeyCredentialClientData(challenge: challenge, origin: origin)
        var requests: [ASAuthorizationRequest] = []

        // プラットフォーム（iCloud キーチェーン等のパスキー）
        if attachment != "cross-platform" {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
            let request = provider.createCredentialRegistrationRequest(
                clientData: clientData, name: name, userID: userID)
            request.userVerificationPreference = uv
            requests.append(request)
        }

        // セキュリティキー（YubiKey 等）
        if attachment != "platform" {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
            let request = provider.createCredentialRegistrationRequest(
                clientData: clientData, displayName: displayName, name: name, userID: userID)
            request.userVerificationPreference = uv
            request.credentialParameters = credentialParameters(body["pubKeyCredParams"])
            request.residentKeyPreference = residentKey(selection)
            request.attestationPreference = attestation(body["attestation"] as? String)
            request.excludedCredentials = securityKeyDescriptors(body["excludeCredentials"])
            requests.append(request)
        }

        guard !requests.isEmpty else {
            throw PasskeyBridgeFailure(.notSupported("No supported authenticator for the requested attachment."))
        }
        return requests
    }

    // MARK: 認証（navigator.credentials.get）

    private func buildAssertionRequests(body: [String: Any],
                                        rpId: String,
                                        origin: String) throws -> [ASAuthorizationRequest] {
        guard let challengeB64 = body["challenge"] as? String,
              let challenge = Data(base64URL: challengeB64) else {
            throw PasskeyBridgeFailure(.notAllowed("Malformed assertion options."))
        }
        let uv = userVerification(body["userVerification"] as? String)
        let allowed = body["allowCredentials"]
        let clientData = ASPublicKeyCredentialClientData(challenge: challenge, origin: origin)

        let platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let platformRequest = platformProvider.createCredentialAssertionRequest(clientData: clientData)
        platformRequest.userVerificationPreference = uv
        platformRequest.allowedCredentials = descriptorIDs(allowed).map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }

        let skProvider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let skRequest = skProvider.createCredentialAssertionRequest(clientData: clientData)
        skRequest.userVerificationPreference = uv
        skRequest.allowedCredentials = securityKeyDescriptors(allowed)

        return [platformRequest, skRequest]
    }

    // MARK: オプションの変換小物

    private func userVerification(_ s: String?) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch s {
        case "required":    return .required
        case "discouraged": return .discouraged
        default:            return .preferred
        }
    }

    private func residentKey(_ selection: [String: Any]) -> ASAuthorizationPublicKeyCredentialResidentKeyPreference {
        if let rk = selection["residentKey"] as? String {
            switch rk {
            case "required":    return .required
            case "discouraged": return .discouraged
            default:            return .preferred
            }
        }
        return (selection["requireResidentKey"] as? Bool) == true ? .required : .preferred
    }

    private func attestation(_ s: String?) -> ASAuthorizationPublicKeyCredentialAttestationKind {
        switch s {
        case "direct":     return .direct
        case "indirect":   return .indirect
        case "enterprise": return .enterprise
        default:           return .none
        }
    }

    private func credentialParameters(_ raw: Any?) -> [ASAuthorizationPublicKeyCredentialParameters] {
        let algs = (raw as? [[String: Any]])?.compactMap { item -> Int? in
            (item["alg"] as? Int) ?? (item["alg"] as? NSNumber)?.intValue
        } ?? []
        // 何も指定が無ければ ES256(-7) と RS256(-257) を出す（実質の標準）
        let fallback = [-7, -257]
        return (algs.isEmpty ? fallback : algs).map {
            ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
        }
    }

    // allowCredentials / excludeCredentials から id（Data）の一覧を抜く
    private func descriptorIDs(_ raw: Any?) -> [Data] {
        ((raw as? [[String: Any]]) ?? []).compactMap { item in
            (item["id"] as? String).flatMap { Data(base64URL: $0) }
        }
    }

    private func securityKeyDescriptors(_ raw: Any?) -> [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor] {
        ((raw as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = (item["id"] as? String).flatMap({ Data(base64URL: $0) }) else { return nil }
            let listed = ((item["transports"] as? [String]) ?? []).compactMap { s -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
                switch s {
                case "usb":              return .usb
                case "nfc":              return .nfc
                case "ble", "bluetooth": return .bluetooth
                default:                 return nil
                }
            }
            let transports = listed.isEmpty
                ? ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported
                : listed
            return ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: id, transports: transports)
        }
    }

    // MARK: 後始末

    private func finish(_ payload: Any?, _ errorMessage: String?) {
        pendingReply?(payload, errorMessage)
        pendingReply = nil
        controller = nil
    }
}

// throw で PasskeyError を運ぶための包み（enum に Error を直接付けないため）
private struct PasskeyBridgeFailure: Error {
    let error: PasskeyError
    init(_ error: PasskeyError) { self.error = error }
}

// MARK: - シートの結果の受け取り

extension PasskeyBridge: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        // 登録の結果
        if let reg = authorization.credential as? ASAuthorizationPublicKeyCredentialRegistration {
            guard let attestation = reg.rawAttestationObject else {
                finish(nil, PasskeyError.notAllowed("The authenticator returned no attestation object.").jsMessage)
                return
            }
            let isSecurityKey = reg is ASAuthorizationSecurityKeyPublicKeyCredentialRegistration
            finish([
                "op": "create",
                "credentialId": reg.credentialID.base64URLString,
                "clientDataJSON": reg.rawClientDataJSON.base64URLString,
                "attestationObject": attestation.base64URLString,
                "authenticatorAttachment": isSecurityKey ? "cross-platform" : "platform",
                "transports": isSecurityKey ? ["usb"] : ["internal", "hybrid"],
            ] as [String: Any], nil)
            return
        }

        // 認証の結果
        if let assertion = authorization.credential as? ASAuthorizationPublicKeyCredentialAssertion {
            var payload: [String: Any] = [
                "op": "get",
                "credentialId": assertion.credentialID.base64URLString,
                "clientDataJSON": assertion.rawClientDataJSON.base64URLString,
                "authenticatorData": assertion.rawAuthenticatorData.base64URLString,
                "signature": assertion.signature.base64URLString,
            ]
            if let platform = assertion as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                let userID: Data? = platform.userID
                if let userID { payload["userHandle"] = userID.base64URLString }
                payload["authenticatorAttachment"] = "platform"
            } else if let sk = assertion as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion {
                let userID: Data? = sk.userID
                if let userID { payload["userHandle"] = userID.base64URLString }
                payload["authenticatorAttachment"] = "cross-platform"
            }
            finish(payload, nil)
            return
        }

        finish(nil, PasskeyError.notAllowed("Unexpected credential type.").jsMessage)
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let ns = error as NSError
        print("Passkey error: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        if ns.domain == ASAuthorizationError.errorDomain {
            switch ns.code {
            case ASAuthorizationError.canceled.rawValue:
                finish(nil, PasskeyError.notAllowed("The operation was canceled.").jsMessage)
                return
            case 1006: // matchedExcludedCredential
                finish(nil, PasskeyError.invalidState("The authenticator already contains one of the excluded credentials.").jsMessage)
                return
            default:
                break
            }
        }
        // エンタイトルメント未取得だと 1004 でここに落ちる
        finish(nil, PasskeyError.notAllowed("The passkey operation failed (\(ns.code)).").jsMessage)
    }
}

extension PasskeyBridge: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        webView?.window ?? NSApplication.shared.mainWindow ?? ASPresentationAnchor()
    }
}

// MARK: - 返信付きメッセージの受け口

extension PasskeyBridge: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any] else {
            replyHandler(nil, PasskeyError.notAllowed("Malformed passkey request.").jsMessage)
            return
        }
        handle(body: body, frame: message.frameInfo, reply: replyHandler)
    }
}

// MARK: - ページへ注入する polyfill

extension PasskeyBridge {
    // navigator.credentials.create / get の publicKey 要求を横取りして
    // skyscraperPasskey（返信付き）へ流し、返ってきた base64url を
    // PublicKeyCredential 形の応答に組み直す。
    // document start・メインフレーム限定（iframe 内の WebAuthn は権限委譲の
    // 検証が別途要るので、まずは対応しない）
    static let userScript = WKUserScript(
        source: polyfillSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let polyfillSource = #"""
    (() => {
        'use strict';
        if (window.__skyscraperPasskeyInstalled) { return; }
        window.__skyscraperPasskeyInstalled = true;

        const bridge = () => window.webkit?.messageHandlers?.skyscraperPasskey;
        if (!bridge()) { return; }

        // ── base64url ⇄ ArrayBuffer ──
        const bufToB64u = (data) => {
            let bytes;
            if (data instanceof ArrayBuffer) { bytes = new Uint8Array(data); }
            else if (ArrayBuffer.isView(data)) {
                bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            } else { throw new TypeError('Expected a BufferSource.'); }
            let s = '';
            for (let i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
            return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        };
        const b64uToBuf = (s) => {
            const b64 = s.replace(/-/g, '+').replace(/_/g, '/')
                + '='.repeat((4 - (s.length % 4)) % 4);
            const bin = atob(b64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
            return bytes.buffer;
        };

        // Swift からのエラーは "名前|文言" で届く。DOMException に組み直す
        const toDOMException = (e) => {
            const raw = (e && e.message) ? String(e.message) : String(e || '');
            const sep = raw.indexOf('|');
            if (sep > 0) {
                return new DOMException(raw.slice(sep + 1), raw.slice(0, sep));
            }
            return new DOMException(raw || 'The operation failed.', 'NotAllowedError');
        };

        const callBridge = (payload, signal) => {
            if (signal && signal.aborted) {
                return Promise.reject(new DOMException('The operation was aborted.', 'AbortError'));
            }
            const request = bridge().postMessage(payload)
                .catch((e) => { throw toDOMException(e); });
            if (!signal) { return request; }
            // abort されたら JS 側の約束だけ先に破る（OS のシートは残るが実害は無い）
            return new Promise((resolve, reject) => {
                signal.addEventListener('abort', () => {
                    reject(new DOMException('The operation was aborted.', 'AbortError'));
                }, { once: true });
                request.then(resolve, reject);
            });
        };

        const serializeDescriptors = (list) => (Array.isArray(list) ? list : []).map((c) => ({
            type: String(c.type || 'public-key'),
            id: bufToB64u(c.id),
            transports: Array.isArray(c.transports) ? c.transports.map(String) : [],
        }));

        // ── attestationObject から authData を抜く最小 CBOR デコーダ ──
        // getAuthenticatorData() / getPublicKeyAlgorithm() を提供するためだけの物。
        // 解析に失敗したらメソッド自体を生やさない（無いのは合法、壊れた値は違法）
        const cborFirst = (u8) => {
            let i = 0;
            const arg = (info) => {
                if (info < 24) { return info; }
                if (info === 24) { return u8[i++]; }
                if (info === 25) { const v = (u8[i] << 8) | u8[i + 1]; i += 2; return v; }
                if (info === 26) {
                    const v = (u8[i] * 0x1000000) + (u8[i + 1] << 16) + (u8[i + 2] << 8) + u8[i + 3];
                    i += 4; return v;
                }
                throw new Error('cbor: unsupported length');
            };
            const item = () => {
                const b = u8[i++];
                const major = b >> 5;
                const info = b & 31;
                switch (major) {
                    case 0: return arg(info);
                    case 1: return -1 - arg(info);
                    case 2: { const n = arg(info); const s = u8.subarray(i, i + n); i += n; return s; }
                    case 3: { const n = arg(info); const s = u8.subarray(i, i + n); i += n;
                              return new TextDecoder().decode(s); }
                    case 4: { const n = arg(info); const a = [];
                              for (let k = 0; k < n; k++) { a.push(item()); } return a; }
                    case 5: { const n = arg(info); const m = {};
                              for (let k = 0; k < n; k++) { const key = item(); m[key] = item(); }
                              return m; }
                    case 6: { arg(info); return item(); }
                    case 7: {
                        if (info === 20) { return false; }
                        if (info === 21) { return true; }
                        if (info === 22 || info === 23) { return null; }
                        throw new Error('cbor: unsupported simple');
                    }
                }
                throw new Error('cbor: unreachable');
            };
            return item();
        };
        const parseAttestation = (attBuf) => {
            try {
                const m = cborFirst(new Uint8Array(attBuf));
                const authData = (m && m.authData instanceof Uint8Array) ? m.authData : null;
                if (!authData || authData.length < 37) { return null; }
                let alg = null;
                if (authData[32] & 0x40) { // AT フラグ：認証情報が続く
                    const credIdLen = (authData[53] << 8) | authData[54];
                    const key = cborFirst(authData.subarray(55 + credIdLen));
                    if (key && typeof key === 'object' && typeof key[3] === 'number') { alg = key[3]; }
                }
                return { authData: authData.slice().buffer, alg };
            } catch (e) { return null; }
        };

        // ── 応答を PublicKeyCredential 形に組む ──
        const finishCredential = (r) => {
            const response = { clientDataJSON: b64uToBuf(r.clientDataJSON) };
            let parsed = null;
            if (r.op === 'create') {
                response.attestationObject = b64uToBuf(r.attestationObject);
                response.getTransports = () => (r.transports || []).slice();
                parsed = parseAttestation(response.attestationObject);
                if (parsed) {
                    response.getAuthenticatorData = () => parsed.authData;
                    if (parsed.alg !== null) {
                        response.getPublicKeyAlgorithm = () => parsed.alg;
                    }
                }
            } else {
                response.authenticatorData = b64uToBuf(r.authenticatorData);
                response.signature = b64uToBuf(r.signature);
                response.userHandle = r.userHandle ? b64uToBuf(r.userHandle) : null;
            }

            const cred = {
                id: r.credentialId,
                rawId: b64uToBuf(r.credentialId),
                type: 'public-key',
                authenticatorAttachment: r.authenticatorAttachment || null,
                response,
                getClientExtensionResults: () => ({}),
                toJSON() {
                    const json = {
                        id: r.credentialId,
                        rawId: r.credentialId,
                        type: 'public-key',
                        authenticatorAttachment: r.authenticatorAttachment || null,
                        clientExtensionResults: {},
                    };
                    if (r.op === 'create') {
                        json.response = {
                            clientDataJSON: r.clientDataJSON,
                            attestationObject: r.attestationObject,
                            transports: (r.transports || []).slice(),
                        };
                        if (parsed) {
                            json.response.authenticatorData = bufToB64u(parsed.authData);
                            if (parsed.alg !== null) { json.response.publicKeyAlgorithm = parsed.alg; }
                        }
                    } else {
                        json.response = {
                            clientDataJSON: r.clientDataJSON,
                            authenticatorData: r.authenticatorData,
                            signature: r.signature,
                            userHandle: r.userHandle || null,
                        };
                    }
                    return json;
                },
            };
            // instanceof PublicKeyCredential を通す。自前のプロパティが
            // プロトタイプのアクセサを全て影で覆うので、本物の内部スロットは
            // 触られない
            if (window.PublicKeyCredential && PublicKeyCredential.prototype) {
                try { Object.setPrototypeOf(cred, PublicKeyCredential.prototype); } catch (e) {}
            }
            return cred;
        };

        // ── navigator.credentials の横取り ──
        if (!navigator.credentials) {
            try {
                Object.defineProperty(navigator, 'credentials', {
                    value: {}, configurable: true,
                });
            } catch (e) { return; }
        }
        const container = navigator.credentials;
        const nativeCreate = typeof container.create === 'function'
            ? container.create.bind(container) : null;
        const nativeGet = typeof container.get === 'function'
            ? container.get.bind(container) : null;

        container.create = function (options) {
            if (!options || !options.publicKey) {
                return nativeCreate ? nativeCreate(options)
                    : Promise.reject(new DOMException('Not supported.', 'NotSupportedError'));
            }
            const pk = options.publicKey;
            let payload;
            try {
                const selection = pk.authenticatorSelection || {};
                payload = {
                    op: 'create',
                    rp: {
                        id: pk.rp && pk.rp.id ? String(pk.rp.id) : location.hostname,
                        name: pk.rp && pk.rp.name ? String(pk.rp.name) : '',
                    },
                    user: {
                        id: bufToB64u(pk.user.id),
                        name: String(pk.user.name ?? ''),
                        displayName: String(pk.user.displayName ?? ''),
                    },
                    challenge: bufToB64u(pk.challenge),
                    pubKeyCredParams: (pk.pubKeyCredParams || []).map((p) => ({
                        type: String(p.type || 'public-key'),
                        alg: Number(p.alg),
                    })),
                    excludeCredentials: serializeDescriptors(pk.excludeCredentials),
                    authenticatorSelection: {
                        authenticatorAttachment: selection.authenticatorAttachment
                            ? String(selection.authenticatorAttachment) : null,
                        residentKey: selection.residentKey ? String(selection.residentKey) : null,
                        requireResidentKey: !!selection.requireResidentKey,
                        userVerification: selection.userVerification
                            ? String(selection.userVerification) : 'preferred',
                    },
                    attestation: pk.attestation ? String(pk.attestation) : 'none',
                };
            } catch (e) {
                return Promise.reject(e instanceof TypeError ? e : new TypeError(String(e)));
            }
            return callBridge(payload, options.signal).then(finishCredential);
        };

        container.get = function (options) {
            if (!options || !options.publicKey) {
                return nativeGet ? nativeGet(options)
                    : Promise.reject(new DOMException('Not supported.', 'NotSupportedError'));
            }
            // 条件付き UI（アドレスバー autofill）は未対応。
            // isConditionalMediationAvailable が false なので行儀の良いサイトは
            // 呼ばないが、呼ばれてもページ読み込みのたびにシートを出さない
            // （永遠に確定しない約束＝候補が選ばれないのと同じ扱い）
            if (options.mediation === 'conditional') {
                return new Promise(() => {});
            }
            const pk = options.publicKey;
            let payload;
            try {
                payload = {
                    op: 'get',
                    rpId: pk.rpId ? String(pk.rpId) : location.hostname,
                    challenge: bufToB64u(pk.challenge),
                    allowCredentials: serializeDescriptors(pk.allowCredentials),
                    userVerification: pk.userVerification ? String(pk.userVerification) : 'preferred',
                };
            } catch (e) {
                return Promise.reject(e instanceof TypeError ? e : new TypeError(String(e)));
            }
            return callBridge(payload, options.signal).then(finishCredential);
        };

        // ── 機能検出への回答 ──
        if (!window.PublicKeyCredential) {
            window.PublicKeyCredential = function PublicKeyCredential() {
                throw new TypeError('Illegal constructor');
            };
        }
        try {
            PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable =
                () => Promise.resolve(true);
            PublicKeyCredential.isConditionalMediationAvailable =
                () => Promise.resolve(false);
        } catch (e) {}
    })();
    """#
}
