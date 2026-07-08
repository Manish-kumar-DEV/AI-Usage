import Foundation
import UserNotifications

/// Threshold (85/100%) and pace notifications, deduped per account + metric +
/// reset window in UserDefaults so the 5-minute refresh loop doesn't re-alert.
enum UsageAlerts {
    private static let firedKey = "firedAlerts"
    private static let delegate = BannerDelegate()

    static func evaluate(_ snap: Snapshot, history: UsageHistory, now: Date = Date()) {
        var fired = (UserDefaults.standard.dictionary(forKey: firedKey) as? [String: Double]) ?? [:]
        // Expired entries belong to windows that have rolled over; pruning
        // them (plus the new window's fresh resetEpoch) is the re-arm.
        fired = fired.filter { $0.value > now.timeIntervalSince1970 }

        for account in snap.accounts where account.error == nil {
            let name = Providers.by(id: account.provider)?.displayName ?? account.provider.capitalized
            let title = "\(name) · \(account.email)"
            for metric in account.metrics {
                // Hour-rounded: providers jitter resetsAt by ~1s between
                // fetches, which must not mint a fresh dedup key (re-alert).
                let resetEpoch = Int((metric.resetsAt.map { ($0.timeIntervalSince1970 / 3600).rounded() }) ?? 0)
                let expiry = metric.resetsAt?.timeIntervalSince1970 ?? now.timeIntervalSince1970 + 24 * 3600

                if let level = UsageHistory.crossedThreshold(metric.percent) {
                    let key = "\(account.key)|\(metric.label)|\(level)|\(resetEpoch)"
                    if fired[key] == nil {
                        fired[key] = expiry
                        if level == 100 { // don't follow a 100% alert with a stale 85% one
                            fired["\(account.key)|\(metric.label)|85|\(resetEpoch)"] = expiry
                        }
                        post(title: title, body: "\(metric.label) at \(Int(metric.percent))%. \(timeUntil(metric.resetsAt))")
                    }
                }

                if let resetsAt = metric.resetsAt,
                   let eta = UsageHistory.projectedExhaustion(
                       history.points(for: account.key, metricLabel: metric.label), now: now),
                   eta < resetsAt.addingTimeInterval(-10 * 60) {
                    let key = "pace|\(account.key)|\(metric.label)|\(resetEpoch)"
                    if fired[key] == nil {
                        fired[key] = expiry
                        post(title: title, body: "At this pace you'll hit your \(metric.label) limit "
                            + "~\(formatGap(resetsAt.timeIntervalSince(eta))) before reset.")
                    }
                }
            }
        }
        UserDefaults.standard.set(fired, forKey: firedKey)
    }

    /// Ask for permission lazily, at the first moment there's something to
    /// say; if denied, drop silently (the dedup key is already marked, so we
    /// don't retry every refresh).
    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { deliver(title: title, body: body) }
                }
            case .denied:
                break
            default:
                deliver(title: title, body: body)
            }
        }
    }

    private static func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Shows banners even while the app is frontmost (the panel can be key).
private final class BannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
