import HermesAppKit
import OpenBotUI
import SwiftUI

/// The 72 pt icon rail (`Geometry.serverRailMacOS`).
///
/// The top block is the bots column (`BotRail`): in Hermes the host is not one assistant,
/// it is an address book, so the rail's first job is switching between them. The marks
/// under it are places in this build. The disabled ones are drawn with a reason in their
/// tooltip rather than hidden: a rail whose icons appear over time is harder to learn than
/// one that says what is coming.
struct IconRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 5) {
            BotRail(model: model, store: store)
                .frame(maxHeight: .infinity, alignment: .top)

            Hairline()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            railButton(symbol: "bubble.left.and.bubble.right",
                       label: "Conversations",
                       isActive: true,
                       isEnabled: true,
                       action: {})

            railButton(symbol: "magnifyingglass",
                       label: "Command palette (⌘K)",
                       isActive: store.isPalettePresented,
                       isEnabled: true,
                       action: { store.openPalette() })

            railButton(symbol: "doc.text",
                       label: "Files — arrives with the tools projection",
                       isActive: false,
                       isEnabled: false,
                       action: {})

            railButton(symbol: "clock.arrow.circlepath",
                       label: "History — arrives with the replay store",
                       isActive: false,
                       isEnabled: false,
                       action: {})

            railButton(symbol: "link",
                       label: "Pair host…",
                       isActive: store.isPairSheetPresented,
                       isEnabled: true,
                       action: { store.isPairSheetPresented = true })

            Avatar(model.hostName,
                   size: .small,
                   presence: presence)
                .padding(.top, 8)
                .accessibilityLabel("\(model.hostName) — \(model.connection.label)")
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: Geometry.serverRailMacOS, alignment: .center)
        .frame(maxHeight: .infinity)
        .background(Tokens.sidebar)
    }

    private var presence: Avatar.Presence {
        if model.hasPendingRequests { return .needsYou }
        if model.connection.isLive { return .running }
        return .idle
    }

    private func railButton(symbol: String,
                            label: String,
                            isActive: Bool,
                            isEnabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            guard isEnabled else { return }
            Haptics.selection()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(ink(isActive: isActive, isEnabled: isEnabled))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isActive ? Tokens.controlActive : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func ink(isActive: Bool, isEnabled: Bool) -> Color {
        if !isEnabled { return Tokens.textDim }
        return isActive ? Tokens.textPrimary : Tokens.textMuted
    }
}

// MARK: - Previews

private struct IconRailPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        HStack(spacing: 0) {
            IconRail(model: store.model, store: store)
            Hairline(.vertical)
        }
        .frame(height: 520)
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#Preview("Icon rail") {
    IconRailPreview()
}
