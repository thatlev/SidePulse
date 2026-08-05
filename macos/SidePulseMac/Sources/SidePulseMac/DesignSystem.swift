// DesignSystem.swift — the small set of tokens and controls the popover is
// built from. Everything visual lives here so the panel stays consistent and a
// spacing or colour change is a one-line edit rather than a sweep.

import SwiftUI

enum Theme {
    /// Popover width. Wide enough for a config path to survive truncation and
    /// for three agent rows to keep their action buttons on one line.
    static let panelWidth: CGFloat = 372
    static let panelPadding: CGFloat = 14
    static let cardRadius: CGFloat = 10
    static let stageRadius: CGFloat = 12

    /// Card fill. Deliberately derived from `primary` rather than a fixed grey
    /// so it inverts correctly between light and dark appearance.
    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.08)

    /// The LED stage stays dark in both appearances — it reads as a screen, not
    /// as a panel, and lit LEDs need a dark ground to look lit at all.
    static let stageTop = Color(red: 0.115, green: 0.120, blue: 0.135)
    static let stageBottom = Color(red: 0.052, green: 0.055, blue: 0.066)

    static let live = Color(red: 0.20, green: 0.78, blue: 0.44)
    static let attention = Color(red: 0.98, green: 0.62, blue: 0.16)
    static let fault = Color(red: 0.94, green: 0.32, blue: 0.31)
}

// MARK: - Containers

/// The standard rounded container: hairline border, near-flat fill, no shadow.
/// Shadows inside a popover read as noise, so hierarchy comes from the border.
struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

/// A micro-label above a card. Uppercase with tracking so it separates the
/// groups without competing with the content for weight.
struct SectionLabel<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 2)
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

// MARK: - Status

/// Small filled dot. `glow` is for the one dot that means "this is live right
/// now" — using it everywhere would flatten the signal.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var glow = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: glow ? color.opacity(0.55) : .clear, radius: glow ? 4 : 0)
    }
}

/// The header's state readout: dot + text in a tinted capsule.
struct StatusPill: View {
    let text: String
    let color: Color
    var live = false

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 6, glow: live)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .foregroundStyle(color)
    }
}

// MARK: - Buttons

/// Compact capsule action used for every button in the panel. `prominent`
/// tints it with the accent colour; the plain form is for reversible or
/// secondary actions so only one button per row pulls the eye.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color?
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let accent = tint ?? .accentColor
        let fill: Color = prominent
            ? accent.opacity(configuration.isPressed ? 0.34 : (hovering ? 0.26 : 0.18))
            : Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.10 : 0.06))
        let stroke: Color = prominent ? accent.opacity(0.42) : Color.primary.opacity(0.10)

        return configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? accent : Color.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Borderless icon action for the footer, where labels would cost more width
/// than they add clarity. Every use carries a `.help()` tooltip.
struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? Color.accentColor : Color.primary.opacity(0.7))
            .frame(width: 26, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)))
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Rows

/// Label/value line used by the activity card. The value is monospaced-digit so
/// counters do not jitter their neighbours as they tick.
struct StatRow: View {
    let label: String
    let value: String
    var truncateHead = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(truncateHead ? .head : .tail)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 11.5))
    }
}
