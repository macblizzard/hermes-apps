import SwiftUI
import OpenBotUI

// TODO(design-system): the sidebar's search field is not in OpenBotUI yet. Replace this
// with the design system's own field as soon as it lands; the geometry here (32 pt tall,
// 9 pt control radius, `Tokens.control`) is what the spec asks for.

/// The session filter. Local text field with the palette's control geometry.
struct MacSidebarSearchField: View {
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Tokens.textDim)

            TextField("",
                      text: $text,
                      prompt: Text("Search sessions").foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .focused($focused)
                .accessibilityLabel("Search sessions")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the session search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(focused ? Tokens.borderFocus : Tokens.borderStrong, lineWidth: 1)
        )
    }
}

private struct MacSidebarSearchFieldPreview: View {
    @State private var empty = ""
    @State private var filled = "vault"

    var body: some View {
        VStack(spacing: 10) {
            MacSidebarSearchField(text: $empty)
            MacSidebarSearchField(text: $filled)
        }
        .padding(14)
        .frame(width: 280)
        .background(Tokens.sidebar)
        .preferredColorScheme(.dark)
    }
}

#Preview("Sidebar search") {
    MacSidebarSearchFieldPreview()
}
