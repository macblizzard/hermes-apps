import SwiftUI
import OpenBotUI

/// iOS shell. Native chrome only — `NavigationStack`, `.searchable`, `TabView`,
/// `.toolbar` — because that is where the platform's smoothness lives (interactive
/// pop, rubber-band scroll, keyboard avoidance, Liquid Glass on system bars).
@main
struct HermesMobileApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .tint(Tokens.accent)
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack { ChatsScreen() }
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack { RoutinesScreen() }
                .tabItem { Label("Routines", systemImage: "clock") }

            NavigationStack { SettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct ChatsScreen: View {
    @State private var query = ""

    var body: some View {
        List {
            Section {
                EmptyChatsRow()
            } footer: {
                Text("Pair with your Hermes host to load sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textDim)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Chats")
        .searchable(text: $query, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "person.crop.circle").foregroundStyle(Tokens.textMuted)
            }
        }
    }
}

struct EmptyChatsRow: View {
    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Tokens.surfaceRaised)
                .frame(width: 44, height: 44)
                .overlay(Text("H").font(.system(size: 15, weight: .bold)).foregroundStyle(Tokens.textSecondary))
            VStack(alignment: .leading, spacing: 3) {
                Text("No sessions").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tokens.textPrimary)
                Text("Nothing paired yet").font(.system(size: 13)).foregroundStyle(Tokens.textMuted)
            }
            Spacer()
        }
        .listRowBackground(Tokens.sheet)
    }
}

struct RoutinesScreen: View {
    var body: some View {
        List {
            Text("No routines yet").foregroundStyle(Tokens.textMuted)
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Routines")
    }
}

struct SettingsScreen: View {
    var body: some View {
        Form {
            Section("Host") {
                LabeledContent("Hermes host", value: "Not paired")
            }
            Section("Devices") {
                Text("Pairing arrives in M2").foregroundStyle(Tokens.textMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Settings")
    }
}
