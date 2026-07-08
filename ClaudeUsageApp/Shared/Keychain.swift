import CryptoKit
import Foundation

/// Keychain access via the `security` CLI. Claude Code's credential item is
/// ACL'd to processes the user has approved for `security`, which avoids a
/// separate "app wants to access keychain" prompt for our dev-signed binary.
enum Keychain {
    private static func run(_ args: [String]) -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Claude Code's live credentials
    // Claude Code keeps one keychain item per config dir: the default ~/.claude
    // uses service "Claude Code-credentials"; a custom CLAUDE_CONFIG_DIR gets
    // "-<first 8 hex of sha256(NFC path)>" appended. When the keychain is
    // unavailable it writes the same JSON to <configDir>/.credentials.json.

    struct LiveCredentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth
    }

    static var defaultClaudeConfigDir: String { NSHomeDirectory() + "/.claude" }

    static func claudeCodeService(configDir: String) -> String {
        let normalized = configDir.precomposedStringWithCanonicalMapping
        if normalized == defaultClaudeConfigDir { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(suffix)"
    }

    static func readClaudeCodeCredentials(configDir: String) -> LiveCredentials? {
        let r = run(["find-generic-password", "-s", claudeCodeService(configDir: configDir), "-w"])
        if r.status == 0,
           let data = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let creds = try? JSONDecoder().decode(LiveCredentials.self, from: data) {
            return creds
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json"))
        else { return nil }
        return try? JSONDecoder().decode(LiveCredentials.self, from: data)
    }

    /// A Claude Code config dir that has a logged-in account.
    struct ClaudeCodeLogin {
        let configDir: String // absolute path; drives the keychain service name
        let email: String     // oauthAccount hint from .claude.json (display/skip only)
    }

    /// Scan $HOME for ~/.claude plus ~/.claude-* config dirs with an active
    /// login. The default dir's settings live at ~/.claude.json (not inside
    /// ~/.claude); custom dirs keep .claude.json inside the dir.
    static func discoverClaudeCodeLogins() -> [ClaudeCodeLogin] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var logins: [ClaudeCodeLogin] = []
        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] {
            guard name.hasPrefix(".claude") else { continue }
            let dir = home + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let settingsPath = dir == defaultClaudeConfigDir ? home + "/.claude.json" : dir + "/.claude.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["oauthAccount"] as? [String: Any],
                  let email = oauth["emailAddress"] as? String, !email.isEmpty else { continue }
            logins.append(ClaudeCodeLogin(configDir: dir, email: email))
        }
        // Default dir first so it wins dedupe ties, then stable alphabetical.
        return logins.sorted {
            if ($0.configDir == defaultClaudeConfigDir) != ($1.configDir == defaultClaudeConfigDir) {
                return $0.configDir == defaultClaudeConfigDir
            }
            return $0.configDir < $1.configDir
        }
    }

    // MARK: Our own captured accounts
    // Keychain account attribute is "provider:email"; the list of keys lives
    // in UserDefaults. Items saved by the pre-provider version used a bare
    // email — migrate them on first read.

    private static let service = "ClaudeUsageWidget"
    private static let keysKey = "accountKeys"
    private static let legacyEmailsKey = "accountEmails"

    static func savedAccountKeys() -> [String] {
        let defaults = UserDefaults.standard
        var keys = defaults.stringArray(forKey: keysKey) ?? []
        // Migrate legacy bare-email entries to "claude:email".
        if let legacy = defaults.stringArray(forKey: legacyEmailsKey) {
            for email in legacy where !keys.contains("claude:\(email)") {
                if var acct = loadAccount(key: email) {
                    acct.provider = "claude"
                    saveAccount(acct)
                    _ = run(["delete-generic-password", "-s", service, "-a", email])
                } else {
                    keys.append("claude:\(email)")
                }
            }
            defaults.removeObject(forKey: legacyEmailsKey)
            keys = defaults.stringArray(forKey: keysKey) ?? keys
        }
        return keys
    }

    private static func rememberKey(_ key: String) {
        var keys = UserDefaults.standard.stringArray(forKey: keysKey) ?? []
        if !keys.contains(key) {
            keys.append(key)
            UserDefaults.standard.set(keys, forKey: keysKey)
        }
    }

    static func loadAccount(key: String) -> StoredAccount? {
        let r = run(["find-generic-password", "-s", service, "-a", key, "-w"])
        guard r.status == 0,
              let data = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredAccount.self, from: data)
    }

    static func saveAccount(_ account: StoredAccount) {
        guard let data = try? JSONEncoder().encode(account),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = run(["add-generic-password", "-U", "-s", service, "-a", account.key, "-w", json])
        rememberKey(account.key)
    }

    static func deleteAccount(key: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", key])
        let keys = (UserDefaults.standard.stringArray(forKey: keysKey) ?? []).filter { $0 != key }
        UserDefaults.standard.set(keys, forKey: keysKey)
    }
}
