import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// iOS shell.
///
/// Native chrome only — `TabView`, `NavigationStack`, `.searchable`, `.toolbar`, `.sheet`,
/// `.safeAreaInset` — because the platform's smoothness lives there: interactive pop,
/// rubber-band scrolling, keyboard avoidance and the system tab bar. Nothing here draws a
/// fake navigation bar or imitation glass.
@main
struct HermesMobileApp: App {
    @StateObject private var app = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .tint(Tokens.accent)
                .task { await app.start() }
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ChatsTab(model: app.model)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            SettingsTab(model: app.model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $app.isPairingPresented) {
            PairingSheet()
        }
        .onChange(of: scenePhase) { phase in
            // A phone comes back from the background with a dead socket; reconnect once
            // rather than waiting for the user to shake it.
            guard phase == .active,
                  app.isPaired,
                  !app.model.connection.isLive else { return }
            Task { await app.reconnect() }
        }
    }
}

/// The Chats tab owns its own navigation path so switching tabs keeps the pushed
/// conversation where the user left it.
struct ChatsTab: View {
    @ObservedObject var model: AppModel
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ChatsScreen(model: model, onOpenSession: { path.append($0) })
                .navigationDestination(for: SessionID.self) { id in
                    ConversationScreen(model: model, sessionID: id)
                }
        }
        .badge(model.pendingRequests.count)
        // A pushed conversation belongs to the bot it was opened under. Switching bots
        // therefore returns to the list rather than leaving one bot's transcript behind
        // the other bot's sessions.
        .onChange(of: model.selectedBotID) { _ in
            path = NavigationPath()
        }
    }
}

struct SettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            SettingsScreen(model: model)
        }
    }
}

// MARK: - Previews

#Preview("Root · paired") {
    let environment = AppEnvironment.preview()
    RootTabView()
        .environmentObject(environment)
        .preferredColorScheme(.dark)
        .task { await environment.start() }
}

#Preview("Root · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    RootTabView()
        .environmentObject(environment)
        .preferredColorScheme(.dark)
}
