import SwiftUI
import OpenBotUI

/// macOS shell. The three-pane geometry comes straight from OpenBot's
/// `layout-constants.ts`: 72 px rail, 280 px sidebar (drag 128…400), conversation
/// with a 640 px measure, 236 px context panel.
///
/// This file is the shell only — panes are placeholders until App agents land.
@main
struct HermesMacApp: App {
    @State private var sidebarWidth: CGFloat = Geometry.sidebarDefault

    var body: some Scene {
        WindowGroup {
            WorkspaceShell(sidebarWidth: $sidebarWidth)
                .frame(minWidth: Geometry.serverRailMacOS + Geometry.sidebarMin + Geometry.conversationMin,
                       minHeight: 520)
                .background(Tokens.frame)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct WorkspaceShell: View {
    @Binding var sidebarWidth: CGFloat
    @State private var showContext = true

    var body: some View {
        HStack(spacing: 0) {
            IconRail()
            Divider().overlay(Tokens.border)
            SessionSidebar(width: $sidebarWidth)
                .frame(width: sidebarWidth)
            Divider().overlay(Tokens.border)
            ConversationPlaceholder()
            if showContext {
                Divider().overlay(Tokens.border)
                ContextPanel()
                    .frame(width: Geometry.contextPanel)
            }
        }
        .background(Tokens.canvas)
    }
}

struct IconRail: View {
    private let items = ["bubble.left", "person.2", "doc", "clock", "slider.horizontal.3"]
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Tokens.surfaceRaised)
                .frame(width: 36, height: 36)
                .overlay(Text("H").font(.system(size: 13, weight: .bold)).foregroundStyle(Tokens.textSecondary))
                .padding(.bottom, 8)
            ForEach(items.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Image(systemName: items[index])
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(selection == index ? Tokens.textPrimary : Tokens.textDim)
                        .frame(width: 38, height: 38)
                        .background(selection == index ? Tokens.controlActive : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: Geometry.serverRailMacOS)
        .background(Tokens.sidebar)
    }
}

struct SessionSidebar: View {
    @Binding var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Hermes").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tokens.textPrimary)
                Text("cody")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Tokens.accentSoft)
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text("Search sessions").font(.system(size: Tokens.textSM))
                Spacer()
            }
            .foregroundStyle(Tokens.textDim)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Tokens.control)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("NO SESSIONS YET")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.textDim)
                    .padding(.horizontal, 14)
                Text("Pair this Mac with your Hermes host to load sessions.")
                    .font(.system(size: Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
                    .padding(.horizontal, 14)
            }
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("hermes").font(.system(size: 11)).foregroundStyle(Tokens.textMuted)
                    Spacer()
                    Text("offline").font(.system(size: 10)).foregroundStyle(Tokens.textDim)
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Tokens.accent).frame(width: 0, height: 3)
                    }
                    .clipShape(Capsule())
            }
            .padding(10)
            .background(Tokens.control)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(8)
        }
        .background(Tokens.sidebar)
    }
}

struct ConversationPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(Tokens.textDim)
            Text("No conversation selected").font(.system(size: Tokens.textLG)).foregroundStyle(Tokens.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
    }
}

struct ContextPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTEXT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.textDim)
            Text("Files and skills appear here.").font(.system(size: 11.5)).foregroundStyle(Tokens.textDim)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.sidebar)
    }
}
