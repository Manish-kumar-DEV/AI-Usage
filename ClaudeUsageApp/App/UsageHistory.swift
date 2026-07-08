import Foundation

/// Rolling time series of usage percentages, one series per
/// "provider:email|metric label". App-target only — the widget never reads it,
/// so the snapshot.json contract is untouched.
struct UsageHistory: Codable {
    struct Point: Codable {
        let t: Date
        let p: Double
    }

    var series: [String: [Point]] = [:]

    /// Covers the longest (weekly) window with margin.
    static let maxAge: TimeInterval = 8 * 24 * 3600

    static var fileURL: URL {
        Snapshot.fileURL.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    static func load() -> UsageHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return UsageHistory() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(UsageHistory.self, from: data)) ?? UsageHistory()
    }

    func write() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Append one point per metric from a fetch, skipping series already
    /// recorded at this snapshot's timestamp (relaunches reuse fresh
    /// snapshots, and transient fetch failures re-emit prior metrics).
    mutating func record(_ snap: Snapshot) {
        for account in snap.accounts where account.error == nil {
            for metric in account.metrics {
                let key = "\(account.key)|\(metric.label)"
                var pts = series[key] ?? []
                if let last = pts.last, last.t >= snap.updatedAt { continue }
                pts.append(Point(t: snap.updatedAt, p: metric.percent))
                series[key] = pts
            }
        }
        let cutoff = snap.updatedAt.addingTimeInterval(-Self.maxAge)
        for (key, pts) in series {
            let kept = pts.filter { $0.t >= cutoff }
            if kept.isEmpty { series.removeValue(forKey: key) } else { series[key] = kept }
        }
        write()
    }

    func points(for accountKey: String, metricLabel: String) -> [Point] {
        series["\(accountKey)|\(metricLabel)"] ?? []
    }

    // MARK: - Pace math (pure; `now` injected so scripts can time-travel)

    /// The suffix of a series since the current window began: usage only
    /// rises within a window, so a drop in percent marks a reset boundary.
    static func windowSlice(_ pts: [Point]) -> [Point] {
        guard var start = pts.indices.first else { return [] }
        for i in pts.indices.dropFirst() where pts[i].p < pts[i - 1].p {
            start = i
        }
        return Array(pts[start...])
    }

    /// Linear projection of when the current window hits 100%, or nil when
    /// there isn't enough signal (few or stale points, flat or falling usage).
    static func projectedExhaustion(_ pts: [Point], now: Date) -> Date? {
        let window = windowSlice(pts)
        guard window.count >= 3,
              let first = window.first, let last = window.last,
              now.timeIntervalSince(last.t) < 15 * 60,
              last.t.timeIntervalSince(first.t) >= 15 * 60,
              last.p < 100, last.p > first.p else { return nil }
        let slope = (last.p - first.p) / last.t.timeIntervalSince(first.t) // % per second
        return last.t.addingTimeInterval((100 - last.p) / slope)
    }

    /// Highest alert threshold a percentage has crossed (100 before 85), so
    /// a jump straight past both fires a single notification.
    static func crossedThreshold(_ percent: Double) -> Int? {
        if percent >= 100 { return 100 }
        if percent >= 85 { return 85 }
        return nil
    }
}

/// Duration like "2h 10m" / "3d 4h" / "5m" for alert and pace copy.
func formatGap(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    let h = s / 3600, m = (s % 3600) / 60
    if h > 24 { return "\(h / 24)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
