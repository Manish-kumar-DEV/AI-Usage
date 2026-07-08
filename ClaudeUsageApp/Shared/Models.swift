import Foundation

// MARK: - Stored account (Keychain)

struct StoredAccount: Codable {
    var provider: String = "claude"
    let email: String
    var plan: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double? // ms since epoch
    var extra: [String: String]? // provider-specific, e.g. Gemini project id

    var key: String { "\(provider):\(email)" }

    init(provider: String, email: String, plan: String,
         accessToken: String, refreshToken: String?, expiresAt: Double?,
         extra: [String: String]? = nil) {
        self.provider = provider
        self.email = email
        self.plan = plan
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.extra = extra
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        email = try c.decode(String.self, forKey: .email)
        plan = try c.decode(String.self, forKey: .plan)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra)
    }
}

// MARK: - Snapshot shared with the widget

struct AccountUsage: Codable {
    struct Metric: Codable {
        let label: String     // "Session", "Week · all models", ...
        let percent: Double
        let resetsAt: Date?
        var priority: Int     // lower = more "current" (Session/5h = 0); headline prefers these

        init(label: String, percent: Double, resetsAt: Date?, priority: Int = 5) {
            self.label = label
            self.percent = percent
            self.resetsAt = resetsAt
            self.priority = priority
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            percent = try c.decode(Double.self, forKey: .percent)
            resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
            priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 5
        }
    }
    var provider: String = "claude"
    let email: String
    let plan: String
    let metrics: [Metric]
    let error: String?

    init(provider: String, email: String, plan: String, metrics: [Metric], error: String?) {
        self.provider = provider
        self.email = email
        self.plan = plan
        self.metrics = metrics
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        email = try c.decode(String.self, forKey: .email)
        plan = try c.decode(String.self, forKey: .plan)
        metrics = try c.decode([Metric].self, forKey: .metrics)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    /// Stable identity matching StoredAccount.key ("provider:email").
    var key: String { "\(provider):\(email)" }

    /// The metric closest to its limit — the account's most-at-risk number.
    var worstMetric: Metric? { metrics.max { $0.percent < $1.percent } }

    /// The number to headline on the ring: the "current" window that each
    /// provider tags with the lowest priority (Session for Claude, 5-hour for
    /// Gemini), UNLESS a longer window is critically high (≥85%), in which case
    /// that urgent one wins.
    var headlineMetric: Metric? {
        guard !metrics.isEmpty else { return nil }
        if let critical = metrics.filter({ $0.percent >= 85 }).max(by: { $0.percent < $1.percent }) {
            return critical
        }
        return metrics.min { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            let ra = a.resetsAt ?? .distantFuture
            let rb = b.resetsAt ?? .distantFuture
            if ra != rb { return ra < rb }
            return a.percent > b.percent   // final tie-break → show the busier one
        }
    }
}

struct Snapshot: Codable {
    let updatedAt: Date
    let accounts: [AccountUsage]

    static var fileURL: URL {
        // Resolve the real home directory so the sandboxed widget (whose
        // FileManager home points at its container) reads the same file the
        // menu bar app writes.
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let dir = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/ClaudeUsage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Snapshot.self, from: data)
    }

    func write() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(self) {
            try? data.write(to: Snapshot.fileURL, options: .atomic)
        }
    }
}

// MARK: - Formatting helpers

func timeUntil(_ date: Date?) -> String {
    guard let date else { return "" }
    let seconds = date.timeIntervalSinceNow
    if seconds <= 0 { return "resetting…" }
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    if h > 24 {
        let d = h / 24
        return "Resets in \(d)d \(h % 24)h"
    }
    if h > 0 { return "Resets in \(h)h \(m)m" }
    return "Resets in \(m)m"
}
