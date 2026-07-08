import SwiftUI

// MARK: - Palette
//
// Everything here is pure SwiftUI. WidgetKit archives a widget's view tree and
// renders it out of process, and custom closure-based `NSColor(name:) { … }`
// values do NOT survive that archiving — using one in `.containerBackground`
// makes the whole widget render as a black rectangle. So theme-adaptive
// surfaces are expressed with `Color.primary`/opacity (which adapt and archive)
// or, for the background, a tiny colorScheme-reading view (`WidgetBackground`).

enum Brand {
    // The single data accent: default label colour, red only when near a limit.
    static let danger = Color(red: 0.90, green: 0.26, blue: 0.21)
    static func number(_ percent: Double) -> Color { percent >= 85 ? danger : .primary }

    // Card surfaces — subtle tints off the foreground colour so they adapt to
    // light/dark without any custom NSColor.
    static let cardFill = Color.primary.opacity(0.06)
    static let cardStroke = Color.primary.opacity(0.10)
}

/// Theme-adaptive widget background. A view (not a static Color) so it can read
/// the SwiftUI colorScheme the widget host provides — and it archives cleanly.
struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        scheme == .dark ? Color(white: 0.05) : Color(white: 0.93)
    }
}

// MARK: - Provider marks (real brand logos, from Shared/Assets.xcassets)

/// A provider mark. Pass `color` to render it monochrome (e.g. white on a tile);
/// pass nil to render the logo's native colours (Claude's coral, Antigravity's
/// rainbow gradient).
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 14
    var color: Color? = nil

    var body: some View {
        Group {
            switch provider {
            case "claude": logo("ClaudeMark")
            case "gemini": logo("AntigravityMark")
            default: Circle().fill(color ?? .secondary)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func logo(_ name: String) -> some View {
        if let color {
            Image(name).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).foregroundStyle(color)
        } else {
            Image(name).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

/// The logo in its native colours, ringed by a thin border — no solid fill, so
/// the mark's own colour (not a flat brand tint) carries the identity.
struct ProviderTile: View {
    let provider: String
    var size: CGFloat = 24
    var body: some View {
        Circle()
            .strokeBorder(Color.primary.opacity(0.35), lineWidth: max(1, size * 0.045))
            .frame(width: size, height: size)
            .overlay(ProviderMark(provider: provider, size: size * 0.72))
    }
}

// MARK: - Radial ring gauge (single solid colour, no gradient)

struct RingGauge: View {
    let percent: Double
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4
    var showLabel: Bool = true

    var body: some View {
        let p = max(0, min(100, percent)) / 100
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, p))
                .stroke(Brand.number(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showLabel {
                Text("\(Int(percent))")
                    .font(.system(size: size * 0.34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
    }
}
