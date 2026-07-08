import WidgetKit
import SwiftUI
import AppIntents

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    var selectedKey: String? = nil   // chosen account for the small widget
}

// MARK: - Configurable account (small widget can pick which account to show)

struct AccountEntity: AppEntity, Identifiable {
    var id: String        // "provider:email"
    var email: String
    var providerName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Account" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(email)", subtitle: "\(providerName)")
    }
    static var defaultQuery = AccountQuery()
}

struct AccountQuery: EntityQuery {
    private func all() -> [AccountEntity] {
        (Snapshot.load()?.accounts ?? []).map {
            AccountEntity(id: $0.key, email: $0.email,
                          providerName: $0.provider == "gemini" ? "Antigravity" : "Claude")
        }
    }
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [AccountEntity] { all() }
}

struct SelectAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Account"
    static var description = IntentDescription("Pick which account the small widget shows. Larger sizes show all accounts.")
    @Parameter(title: "Account") var account: AccountEntity?
    init() {}
}

// MARK: - Timeline

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: nil)
    }
    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> UsageEntry {
        UsageEntry(date: .now, snapshot: Snapshot.load(), selectedKey: configuration.account?.id)
    }
    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = UsageEntry(date: .now, snapshot: Snapshot.load(), selectedKey: configuration.account?.id)
        return Timeline(entries: [entry], policy: .after(.now + 15 * 60))
    }
}

/// Deep link back into the app — opens the menu-bar panel, optionally with a
/// specific account expanded.
func widgetOpenURL(_ account: AccountUsage? = nil) -> URL {
    var c = URLComponents()
    c.scheme = "claudeusage"
    c.host = "open"
    if let account { c.queryItems = [URLQueryItem(name: "account", value: account.key)] }
    return c.url ?? URL(string: "claudeusage://open")!
}

// MARK: - Root

struct UsageWidgetView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var accounts: [AccountUsage] { entry.snapshot?.accounts ?? [] }
    private var byUrgency: [AccountUsage] {
        accounts.sorted { ($0.headlineMetric?.percent ?? 0) > ($1.headlineMetric?.percent ?? 0) }
    }
    private var smallAccount: AccountUsage? {
        if let key = entry.selectedKey, let a = accounts.first(where: { $0.key == key }) { return a }
        return byUrgency.first
    }

    var body: some View {
        Group {
            if accounts.isEmpty {
                placeholder
            } else {
                switch family {
                case .systemSmall: if let a = smallAccount { HeroCard(account: a) }
                case .systemLarge: large
                default: medium
                }
            }
        }
        // Small: 12pt inset makes the 22pt circle icon CONCENTRIC with the
        // widget's measured 23pt corner radius (icon centre = corner-arc centre
        // ⇒ inset = 23 − 11), so the gap is uniform along the edges AND around
        // the curve — like the medium card's icon. Medium 13; large 13/10.
        .padding(.horizontal, family == .systemSmall ? 12 : 13)
        .padding(.vertical, family == .systemSmall ? 12 : family == .systemLarge ? 10 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(widgetOpenURL(family == .systemSmall ? smallAccount : nil))
    }

    private func rows(_ items: [AccountUsage]) -> [[AccountUsage]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    // Cards fill the available height so the outer padding stays uniform on all
    // four sides regardless of family or account count.
    private var medium: some View {
        let shown = Array(byUrgency.prefix(4))
        return VStack(spacing: 8) {
            ForEach(Array(rows(shown).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, a in
                        Link(destination: widgetOpenURL(a)) { MiniCard(account: a) }
                    }
                    if row.count < 2 { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var large: some View {
        let shown = Array(accounts.prefix(6))   // snapshot is already provider-grouped
        return VStack(spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, a in
                Link(destination: widgetOpenURL(a)) { WideCard(account: a) }
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            ProviderTile(provider: "claude", size: 34).unredacted()
            Text("AI Usage").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
            Text("Open the AI Usage menu bar app to load your accounts.")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main
struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "AIUsageRings", intent: SelectAccountIntent.self, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("AI Usage")
        .description("Claude and Antigravity plan usage limits and reset times.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
