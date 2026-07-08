import WidgetKit
import SwiftUI
import AppIntents

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    var selectedKey: String? = nil       // chosen account for the small widget
    var providerFilter: String? = nil    // provider id, nil = all providers
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

/// Per-widget provider filter, so several placed widgets can each track one
/// provider's accounts (the widget can't scroll, so this is how many
/// accounts scale: one widget per provider).
enum ProviderChoice: String, AppEnum {
    case all, claude, antigravity

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Provider" }
    static var caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .all: "All providers", .claude: "Claude", .antigravity: "Antigravity",
    ]

    var providerID: String? {
        switch self {
        case .all: return nil
        case .claude: return "claude"
        case .antigravity: return "gemini"
        }
    }
}

struct SelectAccountIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Account"
    static var description = IntentDescription("Filter the widget to one provider, or pick the single account the small widget shows.")
    @Parameter(title: "Provider", default: .all) var provider: ProviderChoice?
    @Parameter(title: "Account") var account: AccountEntity?
    init() {}
}

// MARK: - Timeline

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: nil)
    }
    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> UsageEntry {
        UsageEntry(date: .now, snapshot: Snapshot.load(), selectedKey: configuration.account?.id,
                   providerFilter: configuration.provider?.providerID)
    }
    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = UsageEntry(date: .now, snapshot: Snapshot.load(), selectedKey: configuration.account?.id,
                               providerFilter: configuration.provider?.providerID)
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

    private var accounts: [AccountUsage] {
        let all = entry.snapshot?.accounts ?? []
        guard let filter = entry.providerFilter else { return all }
        return all.filter { $0.provider == filter }
    }
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
        // Medium drops to the large widget's 10pt when the overflow footer
        // needs the extra height (4 cards + footer > the usable 132pt at 13).
        .padding(.vertical, family == .systemSmall ? 12
                 : family == .systemLarge || (family == .systemMedium && accounts.count > 4) ? 10 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(widgetOpenURL(family == .systemSmall ? smallAccount : nil))
    }

    private func rows(_ items: [AccountUsage]) -> [[AccountUsage]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    // Cards fill the available height so the outer padding stays uniform on all
    // four sides regardless of family or account count.
    /// Overflow footer: widgets can't scroll, so surplus accounts are named
    /// rather than silently dropped. Tapping opens the panel, which shows all.
    private func moreRow(_ hidden: Int) -> some View {
        Link(destination: widgetOpenURL()) {
            Text("+\(hidden) more · most urgent shown")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private var medium: some View {
        let shown = Array(byUrgency.prefix(4))
        // The footer only fits alongside 4 cards with tightened spacing/cards.
        let overflowing = accounts.count > shown.count
        return VStack(spacing: overflowing ? 6 : 8) {
            ForEach(Array(rows(shown).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, a in
                        Link(destination: widgetOpenURL(a)) { MiniCard(account: a, compact: overflowing) }
                    }
                    if row.count < 2 { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxHeight: .infinity)
            }
            if overflowing { moreRow(accounts.count - shown.count) }
        }
        .frame(maxHeight: .infinity)
    }

    private var large: some View {
        // Widgets can't scroll; 6 rows only fit with tightened cards
        // (6 × regular 56pt card > the ~334pt of usable height). Beyond 6,
        // show the most urgent 6 plus an overflow footer.
        let overflowing = accounts.count > 6
        let shown = overflowing ? Array(byUrgency.prefix(6)) : accounts   // grouped order when all fit
        let compact = shown.count >= 6
        return VStack(spacing: compact ? 6 : 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, a in
                Link(destination: widgetOpenURL(a)) { WideCard(account: a, compact: compact) }
                    .frame(maxHeight: .infinity)
            }
            if overflowing { moreRow(accounts.count - shown.count) }
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
