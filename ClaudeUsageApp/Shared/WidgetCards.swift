import SwiftUI

// Card views shared by the widget and the offline preview renderer. Committed
// dark, high-contrast, typography-forward: white numbers, muted-grey labels,
// a single solid ring for the headline, one provider-colour tile for identity.

private let ink = Color.primary
private let mute = Color.secondary

func widgetReset(_ date: Date?) -> String {
    guard let date else { return "" }
    let s = date.timeIntervalSinceNow
    if s <= 0 { return "now" }
    let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
    if h > 24 { return "\(h / 24)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func otherMetrics(_ account: AccountUsage) -> [AccountUsage.Metric] {
    guard let head = account.headlineMetric else { return account.metrics }
    var dropped = false
    return account.metrics.filter { m in
        if !dropped, m.label == head.label, m.percent == head.percent { dropped = true; return false }
        return true
    }
}

/// Short label for the secondary stats ("Claude/GPT · Week" → "3P Wk").
func chipLabel(_ label: String) -> String {
    label.replacingOccurrences(of: "Week · all models", with: "All")
        .replacingOccurrences(of: "Claude/GPT", with: "3P")
        .replacingOccurrences(of: "Gemini", with: "Gem")
        .replacingOccurrences(of: "Week", with: "Wk")
        .replacingOccurrences(of: " · ", with: " ")
}

private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
    content()
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.cardStroke, lineWidth: 0.5))
}

private struct PlanBadge: View {
    let plan: String
    var body: some View {
        Text(plan).font(.system(size: 8, weight: .semibold)).foregroundStyle(mute)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// A "value / label" stat, à la the reference dashboards.
private struct Stat: View {
    let value: String
    let label: String
    var valueColor: Color = ink
    var valueSize: CGFloat = 12
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: valueSize, weight: .semibold).monospacedDigit()).foregroundStyle(valueColor)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(mute)
        }
    }
}

// MARK: - Small (hero)

struct HeroCard: View {
    let account: AccountUsage

    // Header/caption are overlays, NOT stack members: a VStack whose content is
    // taller than the widget overflows the outer padding symmetrically (measured
    //: icon rendered at 3.5pt from the top with a 10pt padding). Overlays pin to
    // the padded bounds no matter what, so the corner inset is exact.
    var body: some View {
        ZStack {
            if let head = account.headlineMetric {
                // Nudged down to centre the ring in the band between the header
                // (bottom ≈ 34pt) and the caption, instead of the whole widget —
                // otherwise its top edge crowds the email line.
                RingGauge(percent: head.percent, size: 84, lineWidth: 9)
                    .offset(y: 6)
            } else if let error = account.error {
                Text(error).font(.system(size: 10)).foregroundStyle(mute).lineLimit(3).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 7) {
                ProviderTile(provider: account.provider, size: 22)
                Text(account.email).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink).lineLimit(1).truncationMode(.middle)
            }
        }
        .overlay(alignment: .bottom) {
            if let head = account.headlineMetric {
                Text("\(head.label)\(widgetReset(head.resetsAt).isEmpty ? "" : " · resets \(widgetReset(head.resetsAt))")")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(mute).lineLimit(1)
            }
        }
    }
}

// MARK: - Medium grid cell

struct MiniCard: View {
    let account: AccountUsage
    var compact = false   // tightened so 4 cards + overflow footer fit the medium widget
    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ProviderTile(provider: account.provider, size: 16)
                    Text(account.email).font(.system(size: 9, weight: .semibold)).foregroundStyle(ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    PlanBadge(plan: account.plan)
                }
                Spacer(minLength: 0)
                if let head = account.headlineMetric {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(head.percent))").font(.system(size: compact ? 20 : 24, weight: .bold).monospacedDigit()).foregroundStyle(Brand.number(head.percent))
                        Text("%").font(.system(size: 11, weight: .semibold)).foregroundStyle(mute)
                        Spacer(minLength: 4)
                        Text(head.label).font(.system(size: 9, weight: .medium)).foregroundStyle(mute).lineLimit(1)
                    }
                } else if account.error != nil {
                    Text("session error").font(.system(size: 10)).foregroundStyle(Brand.danger)
                }
            }
            .padding(compact ? 6 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Large row

struct WideCard: View {
    let account: AccountUsage
    var compact = false   // tightened metrics so 6 rows fit the large widget
    private var ringSize: CGFloat { compact ? 34 : 40 }
    var body: some View {
        card {
            HStack(spacing: 12) {
                if account.headlineMetric != nil {
                    RingGauge(percent: account.headlineMetric!.percent, size: ringSize, lineWidth: 4)
                } else {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                        Image(systemName: "exclamationmark").font(.system(size: 14, weight: .bold)).foregroundStyle(mute)
                    }.frame(width: ringSize, height: ringSize)
                }
                VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                    HStack(spacing: 6) {
                        ProviderTile(provider: account.provider, size: 17)
                        Text(account.email).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).lineLimit(1).truncationMode(.middle)
                        PlanBadge(plan: account.plan)
                        Spacer(minLength: 4)
                        if let head = account.headlineMetric {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(head.label).font(.system(size: 9, weight: .medium)).foregroundStyle(mute)
                                if !widgetReset(head.resetsAt).isEmpty {
                                    Text(widgetReset(head.resetsAt)).font(.system(size: 8).monospacedDigit()).foregroundStyle(mute.opacity(0.7))
                                }
                            }
                        }
                    }
                    if let error = account.error {
                        Text(error).font(.system(size: 9)).foregroundStyle(mute).lineLimit(1)
                    } else {
                        HStack(spacing: 13) {
                            ForEach(Array(otherMetrics(account).prefix(4).enumerated()), id: \.offset) { _, m in
                                Stat(value: "\(Int(m.percent))%", label: chipLabel(m.label), valueColor: Brand.number(m.percent))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, compact ? 5 : 8)
            // Fill the row's share of the height so spare space grows the
            // cards instead of pooling as oversized gaps between rows.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
