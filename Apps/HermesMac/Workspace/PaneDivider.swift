import OpenBotUI
import SwiftUI

/// The 7 pt grab strip between the session list and the conversation.
///
/// OpenBot's sidebar is draggable from 128 to 400 pt and collapses under 110; this gesture
/// is the only way to reach both ends, so it does not clamp at 128 — `WorkspaceStore`
/// decides what a release under 110 means (the 88 pt strip).
struct PaneDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: () -> Void

    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Tokens.canvas)
            Rectangle()
                .fill(hovering ? Tokens.borderFocus : Tokens.border)
                .frame(width: 1)
        }
        .frame(width: 7)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let base = dragStart ?? width
                    let proposed = base + value.translation.width
                    width = min(range.upperBound, max(range.lowerBound, proposed))
                }
                .onEnded { _ in
                    dragStart = nil
                    onCommit()
                }
        )
        .accessibilityLabel("Resize the session list")
    }
}

// MARK: - Previews

private struct PaneDividerPreview: View {
    @State private var width: CGFloat = Geometry.sidebarDefault

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: width)
            PaneDivider(width: $width,
                        range: 64...Geometry.sidebarMax,
                        onCommit: {})
            Color.clear.frame(maxWidth: .infinity)
        }
        .frame(width: 640, height: 320)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#Preview("Pane divider") {
    PaneDividerPreview()
}
