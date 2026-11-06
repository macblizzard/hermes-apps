import SwiftUI

/// Original geometric robot portraits. These are not representations of existing characters.
public enum BotIcon: String, CaseIterable, Identifiable, Codable {
    case ember, nova, cobalt, orbit, moss, dusk
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    fileprivate var tint: Color {
        switch self {
        case .ember: return .orange
        case .nova: return .pink
        case .cobalt: return .cyan
        case .orbit: return .purple
        case .moss: return .green
        case .dusk: return .indigo
        }
    }
    fileprivate var variant: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Scalable vector artwork, shared by the macOS and iOS shells.
public struct BotIconPortrait: View {
    public let icon: BotIcon
    public var size: CGFloat
    public var isWorking: Bool


    public init(_ icon: BotIcon, size: CGFloat = 56, isWorking: Bool = false) {
        self.icon = icon; self.size = size; self.isWorking = isWorking
    }
    public var body: some View {
        ZStack {
            Circle().fill(icon.tint.opacity(0.18))
            Circle().strokeBorder(icon.tint.opacity(0.6), lineWidth: 1)
            VStack(spacing: size * 0.035) {
                if icon.variant % 2 == 0 {
                    Capsule().fill(icon.tint).frame(width: size * 0.09, height: size * 0.12)
                } else {
                    Circle().fill(icon.tint).frame(width: size * 0.10, height: size * 0.10)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(icon.tint.opacity(0.85))
                    VStack(spacing: size * 0.08) {
                        HStack(spacing: size * 0.10) {
                            Circle().fill(Color.black.opacity(0.8))
                            Circle().fill(Color.black.opacity(0.8))
                        }.frame(width: size * 0.28, height: size * 0.09)
                        Capsule().fill(Color.black.opacity(0.7))
                            .frame(width: size * (icon.variant % 3 == 0 ? 0.22 : 0.14), height: size * 0.035)
                    }
                }.frame(width: size * 0.54, height: size * 0.43)
            }
            BotWorkingSparks(size: size, color: icon.tint, isWorking: isWorking)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(icon.title) robot icon")
    }

}

/// Shared working indicator that leaves the underlying portrait unchanged.
public struct BotWorkingSparks: View {
    public var size: CGFloat
    public var color: Color
    public var isWorking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat, color: Color, isWorking: Bool) {
        self.size = size; self.color = color; self.isWorking = isWorking
    }

    public var body: some View {
        ZStack {
            if isWorking {
                if reduceMotion {
                    antennaSparks(opacity: 0.65)
                } else {
                    TimelineView(.animation(minimumInterval: 0.12)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                        antennaSparks(opacity: 0.45 + 0.4 * (0.5 + 0.5 * sin(phase * 5)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Small angular arcs frame the antenna without obscuring the face.
    private func antennaSparks(opacity: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.12, y: size * 0.04))
            path.addLine(to: CGPoint(x: size * 0.06, y: size * 0.08))
            path.addLine(to: CGPoint(x: size * 0.11, y: size * 0.10))
            path.addLine(to: CGPoint(x: size * 0.05, y: size * 0.15))
            path.move(to: CGPoint(x: size * 0.38, y: size * 0.04))
            path.addLine(to: CGPoint(x: size * 0.44, y: size * 0.08))
            path.addLine(to: CGPoint(x: size * 0.39, y: size * 0.10))
            path.addLine(to: CGPoint(x: size * 0.45, y: size * 0.15))
        }
        .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: max(1, size * 0.025), lineCap: .round, lineJoin: .round))
        .frame(width: size * 0.5, height: size * 0.2)
        .offset(y: -size * 0.23)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Selection is controlled by the caller; persistence is deliberately not local.
public struct BotIconGallery: View {
    public let selected: BotIcon?
    public let choose: (BotIcon?) -> Void
    public init(selected: BotIcon?, choose: @escaping (BotIcon?) -> Void) {
        self.selected = selected; self.choose = choose
    }
    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], spacing: 18) {
            Button { choose(nil) } label: {
                VStack { Image(systemName: "person.crop.circle").font(.system(size: 48)); Text("Initials") }
                    .frame(maxWidth: .infinity)
            }.accessibilityAddTraits(selected == nil ? .isSelected : [])
            ForEach(BotIcon.allCases) { icon in
                Button { choose(icon) } label: {
                    VStack(spacing: 6) {
                        BotIconPortrait(icon)
                        Text(icon.title).font(.caption)
                        if selected == icon { Image(systemName: "checkmark.circle.fill") }
                    }.frame(maxWidth: .infinity)
                }.accessibilityAddTraits(selected == icon ? .isSelected : [])
            }
        }.buttonStyle(.plain)
    }
}
