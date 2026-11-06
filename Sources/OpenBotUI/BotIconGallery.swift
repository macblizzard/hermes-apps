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
    public init(_ icon: BotIcon, size: CGFloat = 56) { self.icon = icon; self.size = size }
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
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(icon.title) robot icon")
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
