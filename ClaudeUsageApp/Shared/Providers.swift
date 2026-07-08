import Foundation

enum FetchError: Error {
    case http(Int)
    case unauthorized
    case network(Error)
}

/// One AI provider (Claude, and later OpenAI, Gemini, ...). Each provider
/// knows how to capture credentials from its local tooling and turn them
/// into `AccountUsage` metrics. Everything downstream (menu, widget,
/// snapshot) is provider-agnostic.
protocol AIProvider {
    var id: String { get }          // stable id stored on accounts, e.g. "claude"
    var displayName: String { get } // shown in the UI
    var captureHint: String { get } // where credentials come from, e.g. "Claude Code"
    /// Whether the app can silently snapshot the local login without user
    /// interaction. Claude reads Claude Code's Keychain token (true); the
    /// Gemini/Antigravity flow needs a one-time browser consent (false).
    var supportsAutoCapture: Bool { get }
    /// Capture whatever account the provider's local tooling is logged into.
    func captureLiveAccount() async throws -> StoredAccount
    /// Capture every account the provider's local tooling is logged into
    /// (deduped). Defaults to wrapping the single-account capture.
    func captureLiveAccounts() async throws -> [StoredAccount]
    /// Fetch current usage for a stored account, refreshing tokens as needed.
    func fetch(account: StoredAccount) async -> AccountUsage
}

extension AIProvider {
    func captureLiveAccounts() async throws -> [StoredAccount] { [try await captureLiveAccount()] }
}

enum Providers {
    static let claude = ClaudeProvider()
    static let gemini = GeminiProvider()
    static let all: [AIProvider] = [claude, gemini]

    static func by(id: String) -> AIProvider? {
        all.first { $0.id == id }
    }
}

// MARK: - Claude

struct ClaudeProvider: AIProvider {
    let id = "claude"
    let displayName = "Claude"
    let captureHint = "Claude Code"
    let supportsAutoCapture = true

    // MARK: API responses

    struct UsageResponse: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let displayName: String? }
                let model: Model?
            }
            let kind: String
            let percent: Double?
            let resetsAt: Date?
            let scope: Scope?
        }
        let limits: [Limit]
    }

    struct ProfileResponse: Decodable {
        struct Account: Decodable {
            let email: String
            let hasClaudeMax: Bool?
            let hasClaudePro: Bool?
        }
        let account: Account

        var planName: String {
            if account.hasClaudeMax == true { return "Max" }
            if account.hasClaudePro == true { return "Pro" }
            return "Free"
        }
    }

    // MARK: Endpoints

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code's public OAuth client id
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURLs = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
    ]

    private func get<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw FetchError.network(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw FetchError.unauthorized }
        guard code == 200 else { throw FetchError.http(code) }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad date \(s)"))
        }
        return try dec.decode(T.self, from: data)
    }

    /// OAuth refresh-token grant.
    private func refresh(refreshToken: String) async throws -> (access: String, refresh: String?, expiresAt: Double?) {
        var lastError: Error = FetchError.unauthorized
        for url in Self.tokenURLs {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": Self.clientID,
            ])
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    lastError = FetchError.http(code)
                    continue
                }
                struct TokenResponse: Decodable {
                    let access_token: String
                    let refresh_token: String?
                    let expires_in: Double?
                }
                let t = try JSONDecoder().decode(TokenResponse.self, from: data)
                let expiresAt = t.expires_in.map { Date().timeIntervalSince1970 * 1000 + $0 * 1000 }
                return (t.access_token, t.refresh_token, expiresAt)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func metrics(from usage: UsageResponse) -> [AccountUsage.Metric] {
        usage.limits.map { limit in
            let label: String
            let priority: Int
            switch limit.kind {
            case "session": label = "Session"; priority = 0
            case "weekly_all": label = "Week · all models"; priority = 2
            case "weekly_scoped": label = "Week · \(limit.scope?.model?.displayName ?? "model")"; priority = 3
            default: label = limit.kind; priority = 5
            }
            return AccountUsage.Metric(label: label, percent: limit.percent ?? 0,
                                       resetsAt: limit.resetsAt, priority: priority)
        }
    }

    // MARK: AIProvider

    func captureLiveAccount() async throws -> StoredAccount {
        guard let first = try await captureLiveAccounts().first else { throw FetchError.unauthorized }
        return first
    }

    /// One account per logged-in Claude Code config dir, deduped by email.
    /// A dir whose token is stale is skipped, never self-refreshed here —
    /// its token belongs to Claude Code (see the note on `fetch`).
    func captureLiveAccounts() async throws -> [StoredAccount] {
        var added: [StoredAccount] = []
        var seen = Set<String>()
        for login in Keychain.discoverClaudeCodeLogins() {
            guard let live = Keychain.readClaudeCodeCredentials(configDir: login.configDir),
                  let profile: ProfileResponse = try? await get(Self.profileURL, token: live.claudeAiOauth.accessToken)
            else { continue }
            guard seen.insert(profile.account.email.lowercased()).inserted else { continue }
            let account = StoredAccount(
                provider: id,
                email: profile.account.email,
                plan: profile.planName,
                accessToken: live.claudeAiOauth.accessToken,
                refreshToken: live.claudeAiOauth.refreshToken,
                expiresAt: live.claudeAiOauth.expiresAt,
                extra: ["configDir": login.configDir]
            )
            Keychain.saveAccount(account)
            added.append(account)
        }
        guard !added.isEmpty else { throw FetchError.unauthorized }
        return added
    }

    /// Token strategy: if the stored token is stale, first try to re-adopt
    /// Claude Code's live token (same account only — refreshing a token that
    /// Claude Code also holds could rotate it and log Claude Code out).
    /// Only accounts *not* currently live in Claude Code self-refresh.
    func fetch(account: StoredAccount) async -> AccountUsage {
        var acct = account

        func usageResult(_ usage: UsageResponse) -> AccountUsage {
            AccountUsage(provider: id, email: acct.email, plan: acct.plan,
                         metrics: metrics(from: usage), error: nil)
        }
        func failure(_ message: String) -> AccountUsage {
            AccountUsage(provider: id, email: acct.email, plan: acct.plan, metrics: [], error: message)
        }

        do {
            let usage: UsageResponse = try await get(Self.usageURL, token: acct.accessToken)
            return usageResult(usage)
        } catch FetchError.unauthorized {
            // Stale token. Try re-adopting from the config dir this account
            // was captured from (accounts saved before configDir tracking
            // fall back to the default ~/.claude).
            let configDir = acct.extra?["configDir"] ?? Keychain.defaultClaudeConfigDir
            if let live = Keychain.readClaudeCodeCredentials(configDir: configDir),
               live.claudeAiOauth.accessToken != acct.accessToken,
               let profile: ProfileResponse = try? await get(Self.profileURL, token: live.claudeAiOauth.accessToken),
               profile.account.email == acct.email {
                acct.accessToken = live.claudeAiOauth.accessToken
                acct.refreshToken = live.claudeAiOauth.refreshToken
                acct.expiresAt = live.claudeAiOauth.expiresAt
                acct.plan = profile.planName
                Keychain.saveAccount(acct)
                if let usage: UsageResponse = try? await get(Self.usageURL, token: acct.accessToken) {
                    return usageResult(usage)
                }
            }
            // Fall back to self-refresh (account not live in Claude Code).
            if let refreshToken = acct.refreshToken,
               let refreshed = try? await refresh(refreshToken: refreshToken) {
                acct.accessToken = refreshed.access
                if let r = refreshed.refresh { acct.refreshToken = r }
                acct.expiresAt = refreshed.expiresAt
                Keychain.saveAccount(acct)
                if let usage: UsageResponse = try? await get(Self.usageURL, token: acct.accessToken) {
                    return usageResult(usage)
                }
            }
            return failure("Session expired — log into this account in Claude Code and re-capture")
        } catch FetchError.http(let code) {
            return failure(code == 429 ? "Rate limited — retrying shortly" : "Fetch failed (HTTP \(code))")
        } catch {
            return failure("Fetch failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Gemini (Antigravity)
// Uses a consented OAuth login (Antigravity's own client + the `aicode` scope)
// to reach the group-based quota summary the Antigravity CLI's /model screen
// shows. The Gemini-CLI token in ~/.gemini can't request `aicode`, so this
// provider mints and stores its own refresh token via a one-time browser
// consent, then refreshes silently.

struct GeminiProvider: AIProvider {
    let id = "gemini"
    let displayName = "Antigravity"
    let captureHint = "Antigravity login"
    let supportsAutoCapture = false

    // Antigravity's public OAuth client (extracted from the CLI binary). The
    // two secrets are tried in order — either satisfies the exchange/refresh.
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecrets = ["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",
                                "GOCSPX-9YQWpF7RWDC0QTdj-YxKMwR0Zts"]
    static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let apiBase = "https://cloudcode-pa.googleapis.com/v1internal"
    static let scope = "openid email profile https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/aicode"
    static let userAgent = "antigravity/cli/1.0.16 (aidev_client; os_type=darwin; arch=arm64; auth_method=consumer)"

    // MARK: API

    private func post<T: Decodable>(_ method: String, token: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: "\(Self.apiBase):\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw FetchError.network(error) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw FetchError.unauthorized }
        guard code == 200 else { throw FetchError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct LoadResponse: Decodable {
        struct Tier: Decodable { let id: String?; let name: String? }
        let currentTier: Tier?
        let paidTier: Tier?
        let cloudaicompanionProject: String?
    }

    private struct QuotaSummary: Decodable {
        struct Bucket: Decodable {
            let displayName: String?
            let window: String?
            let resetTime: String?
            let remainingFraction: Double?
        }
        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }
        let groups: [Group]?
    }

    /// A valid access token, refreshing via the aicode client if near expiry.
    private func freshToken(_ acct: inout StoredAccount) async -> String? {
        if let expiresAt = acct.expiresAt, expiresAt > Date().timeIntervalSince1970 * 1000 + 60_000 {
            return acct.accessToken
        }
        guard let refreshToken = acct.refreshToken,
              let t = await OAuthLoopback.refresh(tokenURL: Self.tokenURL, clientID: Self.clientID,
                                                  clientSecrets: Self.clientSecrets, refreshToken: refreshToken)
        else { return nil }
        acct.accessToken = t.accessToken
        acct.expiresAt = t.expiresAt
        Keychain.saveAccount(acct)
        return t.accessToken
    }

    private func metrics(from summary: QuotaSummary) -> [AccountUsage.Metric] {
        let iso = ISO8601DateFormatter()
        var out: [AccountUsage.Metric] = []
        for group in summary.groups ?? [] {
            let g = shortGroup(group.displayName ?? "")
            for bucket in group.buckets ?? [] {
                guard let frac = bucket.remainingFraction else { continue }
                out.append(AccountUsage.Metric(
                    label: "\(g) · \(shortWindow(bucket.window, bucket.displayName))",
                    percent: (1 - frac) * 100,
                    resetsAt: bucket.resetTime.flatMap { iso.date(from: $0) },
                    priority: bucket.window == "5h" ? 0 : (bucket.window == "weekly" ? 2 : 5)
                ))
            }
        }
        return out
    }

    private func shortGroup(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("gemini") { return "Gemini" }
        if name.localizedCaseInsensitiveContains("claude") { return "Claude/GPT" }
        return name
    }

    private func shortWindow(_ window: String?, _ displayName: String?) -> String {
        switch window {
        case "weekly": return "Week"
        case "5h": return "5h"
        default: return displayName ?? "Limit"
        }
    }

    private func planName(from load: LoadResponse) -> String {
        if load.paidTier?.id == "g1-pro-tier" { return "AI Pro" }
        switch load.currentTier?.id {
        case "free-tier": return "Free"
        case "standard-tier": return "Standard"
        case "legacy-tier": return "Legacy"
        default: return load.currentTier?.name ?? "Gemini"
        }
    }

    /// Decode the `email` claim from an id_token JWT (no signature check —
    /// used only to label the account, never for trust).
    private func email(fromIDToken idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    // MARK: AIProvider

    func captureLiveAccount() async throws -> StoredAccount {
        let tokens = try await OAuthLoopback.run(
            authorizeBase: Self.authorizeURL, tokenURL: Self.tokenURL,
            clientID: Self.clientID, clientSecrets: Self.clientSecrets, scope: Self.scope)

        let load: LoadResponse = try await post("loadCodeAssist", token: tokens.accessToken,
                                                body: ["metadata": ["ideType": "ANTIGRAVITY"]])
        let account = StoredAccount(
            provider: id,
            email: email(fromIDToken: tokens.idToken) ?? "google-account",
            plan: planName(from: load),
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            extra: load.cloudaicompanionProject.map { ["projectId": $0] }
        )
        Keychain.saveAccount(account)
        return account
    }

    func fetch(account: StoredAccount) async -> AccountUsage {
        var acct = account
        func failure(_ msg: String) -> AccountUsage {
            AccountUsage(provider: id, email: acct.email, plan: acct.plan, metrics: [], error: msg)
        }
        guard let token = await freshToken(&acct) else {
            return failure("Session expired — remove and re-add via Add Account ▸ Antigravity")
        }
        do {
            // Project id is captured at login; recover it if missing.
            var project = acct.extra?["projectId"]
            if project == nil {
                let load: LoadResponse = try await post("loadCodeAssist", token: token,
                                                        body: ["metadata": ["ideType": "ANTIGRAVITY"]])
                project = load.cloudaicompanionProject
                if let p = project {
                    acct.extra = (acct.extra ?? [:]).merging(["projectId": p]) { _, n in n }
                    Keychain.saveAccount(acct)
                }
            }
            guard let project else { return failure("No project id — re-add via Add Account ▸ Antigravity") }
            let summary: QuotaSummary = try await post("retrieveUserQuotaSummary", token: token,
                                                       body: ["project": project])
            return AccountUsage(provider: id, email: acct.email, plan: acct.plan,
                                metrics: metrics(from: summary), error: nil)
        } catch FetchError.unauthorized {
            return failure("Access denied — remove and re-add via Add Account ▸ Antigravity")
        } catch FetchError.http(let code) {
            return failure(code == 429 ? "Rate limited — retrying shortly" : "Fetch failed (HTTP \(code))")
        } catch {
            return failure("Fetch failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Coordinator

enum UsageService {
    /// Fetch all saved accounts across providers and persist the snapshot.
    /// Each provider's currently-signed-in local account is auto-captured
    /// once (flagged in UserDefaults so removing it later sticks).
    static func fetchAll() async -> Snapshot {
        for provider in Providers.all where provider.supportsAutoCapture {
            let flag = "autoCaptured.\(provider.id)"
            if !UserDefaults.standard.bool(forKey: flag),
               (try? await provider.captureLiveAccounts())?.isEmpty == false {
                UserDefaults.standard.set(true, forKey: flag)
            }
        }
        // Last snapshot, so a transient failure (e.g. a 429 rate-limit) keeps
        // showing last-known numbers instead of blanking the account.
        let previous = Snapshot.load()
        func isTransient(_ message: String) -> Bool {
            let m = message.lowercased()
            return !m.contains("expired") && !m.contains("re-add") && !m.contains("re-capture")
        }

        var results: [AccountUsage] = []
        for key in Keychain.savedAccountKeys() {
            guard let acct = Keychain.loadAccount(key: key),
                  let provider = Providers.by(id: acct.provider) else { continue }
            var result = await provider.fetch(account: acct)
            if let err = result.error, isTransient(err),
               let prior = previous?.accounts.first(where: { $0.key == acct.key }),
               !prior.metrics.isEmpty {
                result = AccountUsage(provider: result.provider, email: result.email,
                                      plan: result.plan, metrics: prior.metrics, error: nil)
            }
            results.append(result)
        }
        // Group by provider so the UI reads as sections, not a scatter.
        results.sort {
            $0.provider != $1.provider ? $0.provider < $1.provider : $0.email < $1.email
        }
        let snapshot = Snapshot(updatedAt: Date(), accounts: results)
        snapshot.write()
        return snapshot
    }
}
