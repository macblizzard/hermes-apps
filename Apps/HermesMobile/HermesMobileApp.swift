import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// iOS shell.
///
/// Native chrome only — `TabView`, `NavigationStack`, `.searchable`, `.toolbar`, `.sheet` —
/// because the platform's smoothness lives there: interactive pop, rubber-band scrolling,
/// keyboard avoidance and the system tab bar. Nothing here draws a fake navigation bar or
/// imitation glass.
///
/// Two tabs, because there are two things the app can do: talk to a bot, and change how it
/// talks. The first tab *is* the bot directory — no drawer, no hidden switcher, no session
/// list (`docs/ENDLESS-CHAT.md` §1).
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
            BotsTab(model: app.model)
                .tabItem { Label("Bots", systemImage: "person.2") }

            SettingsTab(model: app.model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $app.isPairingPresented) {
            PairingSheet()
        }
        .onChange(of: scenePhase) { phase in
            // A phone comes back from the background with a dead socket; reconnect once
            // rather than waiting for the user to shake it. A host the user disconnected on
            // purpose stays disconnected — that is a choice, not a dropped socket.
            guard phase == .active, app.isPaired, !app.isDisconnectedByUser else { return }
            Task {
                if app.model.connection.isLive { await app.loadBotIcons() }
                else { await app.reconnect() }
            }
        }
    }
}

/// The bots tab owns its own navigation path so switching tabs keeps the pushed
/// conversation where the user left it.
///
/// One conversation per bot is the whole model, so the path holds a `Bot` and nothing else:
/// there is no session to address, and going back is the only way out of a thread.
struct BotsTab: View {
    @ObservedObject var model: AppModel
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            BotListScreen(model: model, onOpenBot: { path.append($0) })
                .navigationDestination(for: Bot.self) { bot in
                    ConversationScreen(model: model, bot: bot)
                }
        }
        .badge(model.pendingRequests.count)
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
