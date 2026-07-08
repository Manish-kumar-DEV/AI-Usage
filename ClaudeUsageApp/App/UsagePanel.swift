import SwiftUI

private let panelWidth: CGFloat = 344

/// NSVisualEffectView bridge so the borderless panel gets a native menu
/// material background (blur + vibrancy) instead of the popover chrome.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Severity tint by how close a metric is to its limit.
func usageTint(_ percent: Double) -> Color {
    switch percent {
    case ..<60: return .blue
    case ..<85: return .orange
    default: return .red
    }
}

// MARK: - Provider identity (glyph + brand color)

struct ProviderStyle {
    let glyph: String
    let color: Color
    let name: String
}

func providerStyle(_ id: String) -> ProviderStyle {
    switch id {
    case "claude": return ProviderStyle(glyph: "✳", color: Color(red: 0.85, green: 0.47, blue: 0.34), name: "Claude")
    case "gemini": return ProviderStyle(glyph: "✦", color: Color(red: 0.29, green: 0.53, blue: 0.96), name: "Antigravity")
    default: return ProviderStyle(glyph: "●", color: .secondary, name: id.capitalized)
    }
}

/// Reset like "3h 4m" / "2d 5h" / "now".
private func panelReset(_ date: Date?) -> String {
    guard let date else { return "" }
    let s = date.timeIntervalSinceNow
    if s <= 0 { return "now" }
    let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
    if h > 24 { return "\(h / 24)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Shared state between AppDelegate and the popover

final class PanelModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var refreshing = false
    @Published var selectedKey: String?   // "provider:email" of the expanded account

    var onRefresh: () -> Void = {}
    var onAdd: (String) -> Void = { _ in }      // provider id
    var onRemove: (String) -> Void = { _ in }   // "provider:email"
    var onQuit: () -> Void = {}
}

// MARK: - Panel

struct UsagePanelView: View {
    @ObservedObject var model: PanelModel

    private var accounts: [AccountUsage] { model.snapshot?.accounts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if accounts.isEmpty {
                empty
            } else if accounts.count > 6 {
                // Only large account lists scroll; the panel otherwise sizes to
                // its content so nothing overflows (and no scrollbar flickers
                // in mid-expand).
                ScrollView { content }
                    .frame(maxHeight: 560)
                    .scrollIndicators(.hidden)
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(width: panelWidth)
        // Blur + a semi-opaque system-background scrim: native menus keep a
        // strong dark base under the vibrancy, so bright windows behind the
        // panel can't wash it out grey.
        .background {
            VisualEffectView()
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerSections
            if let key = model.selectedKey,
               let account = accounts.first(where: { $0.key == key }) {
                AccountDetailView(account: account) { model.onRemove(key) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("Tap a ring to see its limits.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("AI Usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.refreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            } else if let updated = model.snapshot?.updatedAt {
                Text(updated, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(action: model.onRefresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Account rings grouped under a provider header, so many accounts read as
    /// per-provider clusters rather than a flat scatter. Headers are shown only
    /// when more than one provider is present.
    private var providerSections: some View {
        let groups = Providers.all
            .map { provider in (provider, accounts.filter { $0.provider == provider.id }) }
            .filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 8) {
                    if groups.count > 1 { providerHeader(entry.0.id) }
                    ringGrid(for: entry.1)
                }
            }
        }
    }

    private func providerHeader(_ id: String) -> some View {
        let style = providerStyle(id)
        return HStack(spacing: 5) {
            ProviderMark(provider: id, size: 12)
            Text(style.name.uppercased())
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).kerning(0.5)
        }
    }

    private func ringGrid(for group: [AccountUsage]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], alignment: .leading, spacing: 12) {
            ForEach(Array(group.enumerated()), id: \.offset) { _, account in
                RingCell(account: account, selected: model.selectedKey == account.key) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.selectedKey = (model.selectedKey == account.key) ? nil : account.key
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("✳").font(.system(size: 34))
            Text("No accounts yet").font(.system(size: 13, weight: .semibold))
            Text("Add one below to see usage limits.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Array(Providers.all.enumerated()), id: \.offset) { _, provider in
                    Button("\(provider.displayName) — from \(provider.captureHint)") {
                        model.onAdd(provider.id)
                    }
                }
            } label: {
                Label("Add Account", systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Quit", action: model.onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Ring cell

struct RingCell: View {
    let account: AccountUsage
    let selected: Bool
    let onTap: () -> Void

    private var headline: Double { account.headlineMetric?.percent ?? 0 }
    private var tint: Color { account.error != nil ? .gray : usageTint(headline) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.001, min(headline, 100) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if account.error != nil {
                    Image(systemName: "exclamationmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.secondary)
                } else {
                    Text("\(Int(headline))").font(.system(size: 18, weight: .semibold).monospacedDigit())
                }
            }
            .frame(width: 52, height: 52)
            Text(account.email)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 74)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.secondary.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Expanded account detail

struct AccountDetailView: View {
    let account: AccountUsage
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(provider: account.provider, size: 12)
                Text(account.email).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(account.plan)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove account")
            }
            if let error = account.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if account.metrics.isEmpty {
                Text("No limits reported.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(account.metrics.enumerated()), id: \.offset) { _, metric in
                    PanelMetricRow(metric: metric)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }
}

struct PanelMetricRow: View {
    let metric: AccountUsage.Metric

    var body: some View {
        HStack(spacing: 8) {
            Text(metric.label)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: min(metric.percent, 100), total: 100)
                .progressViewStyle(.linear).tint(usageTint(metric.percent))
                .controlSize(.small).frame(width: 60)
            Text("\(Int(metric.percent))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(metric.percent >= 85 ? Color.red : .primary)
                .frame(width: 34, alignment: .trailing)
            Text(panelReset(metric.resetsAt))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 46, alignment: .trailing)
        }
    }
}
