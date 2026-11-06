import SwiftUI

/// The OpenBot design system.
///
/// Every value here is a direct port of `packages/brand/src/tokens.css` from the
/// OpenBot clone (dark palette). That file is the single declaration site upstream;
/// this one is its Swift mirror. Do not add a colour anywhere else in the app — if a
/// component needs a new shade, add the token here first, with the upstream name in
/// the comment, so the two files can be diffed.
public enum Tokens {

    // MARK: Surfaces
    public static let canvas = Color(hex: 0x1A1A1A)          // --openbot-bg-canvas
    public static let frame = Color(hex: 0x0D0D0D)           // --openbot-bg-frame
    public static let sidebar = Color(hex: 0x1A1A1A)         // --openbot-bg-sidebar
    public static let surface = Color(hex: 0x212121)         // --openbot-bg-surface
    public static let surfaceRaised = Color(hex: 0x242424)   // --openbot-bg-surface-raised
    public static let control = Color(hex: 0x212121)         // --openbot-bg-control
    public static let controlHover = Color(hex: 0x242424)    // --openbot-bg-control-hover
    public static let controlActive = Color(hex: 0x2A2A2A)   // --openbot-bg-control-active
    public static let sheet = Color(hex: 0x141414)           // --openbot-bg-sheet
    public static let sheetInset = Color(hex: 0x101010)      // --openbot-bg-sheet-inset
    public static let grouped = Color(hex: 0x212121)         // --openbot-bg-grouped

    // MARK: Text
    public static let textPrimary = Color(hex: 0xFFFFFF)     // --openbot-text-primary
    public static let textSecondary = Color(hex: 0xDCDCDC)   // --openbot-text-secondary
    public static let textMuted = Color(hex: 0x979797)       // --openbot-text-muted
    public static let textDim = Color(hex: 0x6A6A6A)         // --openbot-text-dim
    public static let textPlaceholder = Color(hex: 0xBFBFBF) // --openbot-text-placeholder
    public static let textGroupedSecondary = Color(hex: 0x96969B)

    // MARK: Accent and status
    public static let accent = Color(hex: 0x007CF7)          // --openbot-accent
    public static let accentHover = Color(hex: 0x1F8FFF)     // --openbot-accent-hover
    public static let accentText = Color(hex: 0x42A0FF)      // --openbot-accent-text
    public static let accentSoft = Color(hex: 0x007CF7, opacity: 0.16)
    public static let success = Color(hex: 0x31CF76)
    public static let successSoft = Color(hex: 0x31CF76, opacity: 0.12)
    public static let warning = Color(hex: 0xFF9412)
    public static let warningSoft = Color(hex: 0xFF9412, opacity: 0.12)
    public static let danger = Color(hex: 0xFD2F3B)
    public static let dangerSoft = Color(hex: 0xFD2F3B, opacity: 0.16)

    // MARK: Borders
    public static let border = Color.white.opacity(0.035)       // --openbot-border
    public static let borderStrong = Color.white.opacity(0.045) // --openbot-border-strong
    public static let borderGrouped = Color(hex: 0x333335)
    public static let borderFocus = textMuted

    // MARK: Radius
    public static let radiusGrouped: CGFloat = 16
    public static let radiusCard: CGFloat = 12
    public static let radiusControl: CGFloat = 9
    public static let radiusSmall: CGFloat = 6

    // MARK: Type scale (--openbot-text-sm/md/lg/xl)
    public static let textSM: CGFloat = 12
    public static let textMD: CGFloat = 13
    public static let textLG: CGFloat = 14
    public static let textXL: CGFloat = 16

    /// Chat body. OpenBot draws chat text at 16 pt on a 22 pt line on iOS and 14/1.62
    /// on the desktop; both are one table there (`chat-text-styles.ts`) and one table
    /// here, so every way of drawing a message agrees.
    public static let chatBodyMacOS: CGFloat = 14
    public static let chatBodyIOS: CGFloat = 16
    public static let chatLineIOS: CGFloat = 22

    public static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

// MARK: - Geometry (src/renderer/src/layout-constants.ts)

public enum Geometry {
    public static let serverRailMacOS: CGFloat = 72      // MAC_SERVER_RAIL_WIDTH
    public static let serverRail: CGFloat = 64           // SERVER_RAIL_WIDTH
    public static let serverRailNarrow: CGFloat = 56     // NARROW_SERVER_RAIL_WIDTH
    public static let sidebarDefault: CGFloat = 280      // LEFT_PANEL_DEFAULT
    public static let sidebarMin: CGFloat = 128
    public static let sidebarMax: CGFloat = 400
    public static let sidebarCompact: CGFloat = 88
    public static let sidebarCollapseBelow: CGFloat = 110
    public static let conversationMin: CGFloat = 424     // CONVERSATION_MIN_WIDTH
    public static let contextPanel: CGFloat = 236
    public static let conversationMeasure: CGFloat = 640
    /// One inset for the conversation column: header, transcript, approval cards, composer and
    /// error strips all start here, so their left edges cannot drift apart.
    public static let readingInset: CGFloat = 24
    /// One inset for the bot panel: its header, rows, empty states and host chip agree.
    public static let sidebarInset: CGFloat = 12
    /// The window's own rounded clip, and the floating palette's.
    public static let radiusWindow: CGFloat = 13
    public static let radiusPalette: CGFloat = 14
    /// The divider between the bot panel and the conversation (hit area, not visual width).
    public static let paneDivider: CGFloat = 7
}

// MARK: - Helpers

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

public extension View {
    /// The 1 px hairline every OpenBot surface uses.
    func hairlineBorder(_ radius: CGFloat = Tokens.radiusCard) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
    }
}
