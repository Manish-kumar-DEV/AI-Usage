import Foundation
import AppKit
import Network
import CryptoKit

struct OAuthTokens {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?   // ms since epoch
    let idToken: String?
    let scope: String?
}

enum OAuthError: Error {
    case listenerFailed
    case consentTimeout
    case stateMismatch
    case noCode
    case exchangeFailed(String)
}

/// A PKCE authorization-code loopback OAuth flow. Opens the user's browser for
/// consent, captures the redirect on a local port, and exchanges the code for
/// tokens. Used to mint an `aicode`-scoped token for the Antigravity/Gemini
/// provider (the one scope the Gemini-CLI client cannot request).
enum OAuthLoopback {
    static func run(authorizeBase: String,
                    tokenURL: String,
                    clientID: String,
                    clientSecrets: [String],
                    scope: String,
                    callbackPath: String = "/auth/callback",
                    timeout: TimeInterval = 180) async throws -> OAuthTokens {
        let verifier = randomURLSafe(64)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)

        let server = LoopbackServer(callbackPath: callbackPath)
        let port = try server.start()
        defer { server.stop() }
        let redirect = "http://localhost:\(port)\(callbackPath)"

        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        let authURL = comps.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let params = try await server.waitForCallback(timeout: timeout)
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = params["code"] else { throw OAuthError.noCode }

        // Exchange the code, trying each candidate client secret (the two are
        // interchangeable across Antigravity's clients; a wrong one returns
        // invalid_client without consuming the single-use code).
        var lastError = "unknown"
        for secret in clientSecrets {
            let form = [
                "client_id": clientID,
                "client_secret": secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": redirect,
                "code_verifier": verifier,
            ]
            let (status, data) = await postForm(tokenURL, form)
            if status == 200, let tok = decodeTokens(data) {
                return tok
            }
            if let err = errorField(data) {
                lastError = err
                if err == "invalid_client" { continue }
            }
            break
        }
        throw OAuthError.exchangeFailed(lastError)
    }

    /// Refresh-token grant against the same client, trying each secret.
    static func refresh(tokenURL: String, clientID: String,
                        clientSecrets: [String], refreshToken: String) async -> OAuthTokens? {
        for secret in clientSecrets {
            let form = [
                "client_id": clientID,
                "client_secret": secret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ]
            let (status, data) = await postForm(tokenURL, form)
            if status == 200, let tok = decodeTokens(data) { return tok }
            if errorField(data) == "invalid_client" { continue }
            return nil
        }
        return nil
    }

    // MARK: helpers

    private static func decodeTokens(_ data: Data) -> OAuthTokens? {
        struct R: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let id_token: String?
            let scope: String?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        let expiresAt = r.expires_in.map { Date().timeIntervalSince1970 * 1000 + $0 * 1000 }
        return OAuthTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                           expiresAt: expiresAt, idToken: r.id_token, scope: r.scope)
    }

    private static func errorField(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    private static func postForm(_ url: String, _ form: [String: String]) async -> (Int, Data) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(percentEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, Data()) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

// MARK: - Loopback HTTP server (single request)

private final class LoopbackServer {
    private let callbackPath: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var resumed = false
    private let lock = NSLock()

    init(callbackPath: String) { self.callbackPath = callbackPath }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw OAuthError.listenerFailed }
        return port
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); self.continuation = cont; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(OAuthError.consentTimeout))
            }
        }
    }

    func stop() { listener?.cancel() }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !resumed, let cont = continuation else { lock.unlock(); return }
        resumed = true
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let params = self.parseCallback(request)
            let body = """
            <html><head><meta charset='utf-8'></head>
            <body style='font-family:-apple-system,system-ui;background:#1d1d1f;color:#f5f5f7;\
            display:flex;align-items:center;justify-content:center;height:100vh;margin:0'>
            <div style='text-align:center'><div style='font-size:44px'>✳</div>
            <h2>Signed in</h2><p style='opacity:.7'>You can close this tab and return to the app.</p></div>
            </body></html>
            """
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                       "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if params["code"] != nil || params["error"] != nil {
                self.finish(.success(params))
            }
        }
    }

    private func parseCallback(_ request: String) -> [String: String] {
        // First line: "GET /auth/callback?code=...&state=... HTTP/1.1"
        guard let line = request.split(separator: "\r\n").first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix(callbackPath),
              let qIndex = parts[1].firstIndex(of: "?") else { return [:] }
        let query = String(parts[1][parts[1].index(after: qIndex)...])
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return out
    }
}

// MARK: - small crypto/encoding helpers

private func randomURLSafe(_ n: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: n)
    _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
    return base64url(Data(bytes))
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func percentEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
