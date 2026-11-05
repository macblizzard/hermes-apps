import Foundation
import SwiftUI

/// How full the context window is.
///
/// Three levels, not a colour ramp: below 70% nothing has to happen, above 70% the turn
/// is filling up, above 85% the thread is about to compact. The number is always printed
/// — the ring is a second channel, never the only one — and the value is clamp-safe, so a
/// provider that reports more tokens than its window cannot draw a circle that overlaps
/// itself.
public struct ContextGauge: View {
    public enum Style {
        case ring
        case bar
    }

    public enum Level: Equatable {
        case ok
        case warn
        case compact

        var tint: Color {
            switch self {
            case .ok: return Tokens.accent
            case .warn: return Tokens.warning
            case .compact: return Tokens.danger
            }
        }

        var word: String {
            switch self {
            case .ok: return "room to spare"
            case .warn: return "filling up"
            case .compact: return "compacts soon"
            }
        }
    }

    private let used: Int
    private let limit: Int
    private let style: Style
    private let showsLabel: Bool
    private let caption: String
    private let side: CGFloat

    public init(used: Int,
                limit: Int,
                style: Style = .ring,
                showsLabel: Bool = false,
                caption: String = "Context",
                side: CGFloat = 40) {
        self.used = max(0, used)
        self.limit = max(0, limit)
        self.style = style
        self.showsLabel = showsLabel
        self.caption = caption
        self.side = side
    }

    public var fraction: CGFloat {
        guard limit > 0 else { return 0 }
        return min(1, max(0, CGFloat(used) / CGFloat(limit)))
    }

    public var percent: Int {
        Int((fraction * 100).rounded())
    }

    public var level: Level {
        if fraction >= 0.85 { return .compact }
        if fraction >= 0.70 { return .warn }
        return .ok
    }

    public var body: some View {
        Group {
            switch style {
            case .ring: ringBody
            case .bar: barBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue("\(percent) percent of \(compact(limit)) tokens")
    }

    // MARK: Ring

    private var ringBody: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Tokens.controlActive, lineWidth: strokeWidth)

                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(level.tint, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text("\(percent)%")
                    .font(TypeScale.font(side >= 36 ? TypeScale.caption : 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(level == .ok ? Tokens.textSecondary : level.tint)
            }
            .frame(width: side, height: side)
            .animation(.easeOut(duration: 0.25), value: fraction)

            if showsLabel {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textMuted)

                    Text("\(compact(used)) / \(compact(limit))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Tokens.textDim)

                    if level != .ok {
                        Text(level.word)
                            .font(TypeScale.font(TypeScale.caption, weight: .medium))
                            .foregroundStyle(level.tint)
                    }
                }
            }
        }
    }

    private var strokeWidth: CGFloat {
        side >= 44 ? 3.5 : 3
    }

    // MARK: Bar

    private var barBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("\(percent)%")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(level == .ok ? Tokens.textDim : level.tint)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.controlActive)
                    Capsule()
                        .fill(level.tint)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 4)

            if showsLabel {
                Text("\(compact(used)) / \(compact(limit)) tokens")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
            }
        }
        .animation(.easeOut(duration: 0.25), value: fraction)
    }

    // MARK: Numbers

    private func compact(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        let thousands = Double(value) / 1_000
        if thousands < 1_000 {
            return trimmed(String(format: "%.1f", thousands)) + "k"
        }
        return trimmed(String(format: "%.1f", thousands / 1_000)) + "m"
    }

    private func trimmed(_ text: String) -> String {
        text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

// MARK: - Previews

#Preview("Context gauge") {
    VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 24) {
            ContextGauge(used: 42_000, limit: 200_000)
            ContextGauge(used: 156_000, limit: 200_000)
            ContextGauge(used: 188_000, limit: 200_000)
        }

        ContextGauge(used: 42_000, limit: 200_000, showsLabel: true)

        ContextGauge(used: 188_000, limit: 200_000, style: .bar, showsLabel: true)
            .frame(width: 200)
    }
    .padding(24)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
