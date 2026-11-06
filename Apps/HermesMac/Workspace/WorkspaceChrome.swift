import Foundation

/// The window surround's geometry, kept free of SwiftUI so it can be unit-tested.
enum WorkspaceChrome {
    /// The frame colour visible to the left, right and bottom of the workspace.
    static let sideInset: CGFloat = 8
    static let bottomInset: CGFloat = 8

    /// The strip reserved for the hidden title bar's traffic lights. Those buttons are
    /// roughly 14 pt tall and sit about 7 pt from the window's top edge, so 28 pt is the
    /// standard macOS title-bar height and leaves them unobstructed.
    static let titleBarHeight: CGFloat = 28

    /// Padding to add *inside* the window's safe area.
    ///
    /// With `.hiddenTitleBar` the system may already reserve the title-bar height as a top
    /// safe-area inset. Adding the full 28 pt on top of that is what produced the double
    /// gap above the workspace. Top up to the traffic-light strip instead, never add a
    /// second one.
    static func topPadding(safeAreaTop: CGFloat) -> CGFloat {
        max(0, titleBarHeight - max(0, safeAreaTop))
    }

    /// Distance from the window's top edge to the workspace once the system inset and our
    /// padding are combined. It is `titleBarHeight` unless the system reserves more.
    static func topOffset(safeAreaTop: CGFloat) -> CGFloat {
        max(0, safeAreaTop) + topPadding(safeAreaTop: safeAreaTop)
    }
}
