import HermesAppKit
import OpenBotUI
import SwiftUI

/// macOS workspace. Rail 72, session list 280 (drag 64…400, collapses under 110 to the
/// 88 pt strip), conversation on a 640 pt measure, context panel 236 — the geometry in
/// `Geometry`, which mirrors OpenBot's `layout-constants.ts`.
///
/// Launch is offline by construction: `WorkspaceStore` restores the pairing it was given
/// last time but dials nothing, and the only calls into `connect()` are the Connect button,
/// the palette's verb and the pair sheet's Pair press.
@main
struct HermesMacApp: App {
    /// Ordinary launch: `WorkspaceStore()`, which restores whatever was paired last time.
    /// UI-test launch: a frozen, offline store built by `UITestFixture`, which is only ever
    /// reachable through the two launch arguments it checks (see that file). The store and the
    /// one `.task` below are the entire hook; nothing else about the window changes.
    @StateObject private var store = UITestFixture.storeForLaunch()

    var body: some Scene {
        WindowGroup("Hermes") {
            WorkspaceRoot(store: store)
                .frame(minWidth: Geometry.serverRailMacOS + Geometry.sidebarMin + Geometry.conversationMin,
                       minHeight: 560)
                .preferredColorScheme(.dark)
                // No-op unless the fixture launch argument was given: the real window connects
                // nothing at launch, on purpose.
                .task { await store.attachFixtureHostIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            WorkspaceCommands(store: store)
        }
        Window("Paired Devices", id: "paired-devices") {
            MacDevicesView(store: store)
        }
        .defaultSize(width: 560, height: 440)
    }
}

/// The menu bar: everything the palette offers that also deserves a key.
///
/// Kept as a plain reference rather than an observed object — menu items read the store when
/// they are chosen (the closure), which is the only moment that has to be right.
struct WorkspaceCommands: Commands {
    let store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                store.newSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!store.model.connection.isLive)

            Button("Pair Host…") {
                store.isPairSheetPresented = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Manage Paired Devices…") {
                openWindow(id: "paired-devices")
            }
        }

        CommandMenu("Session") {
            Button("Send Message") {
                store.send()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canSend)

            Button("Interrupt Turn") {
                store.interrupt()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!store.canInterrupt)

            Divider()

            Button("Reload Sessions") {
                store.reloadSessions()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!store.model.connection.isLive)

            Button(store.model.connection.isLive ? "Disconnect" : "Connect") {
                Task {
                    if store.model.connection.isLive {
                        await store.disconnect()
                    } else {
                        await store.connect()
                    }
                }
            }
            .disabled(!store.isPaired)

            Divider()

            Button("Command Palette…") {
                store.openPalette()
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button(store.showsContextPanel ? "Hide Context Panel" : "Show Context Panel") {
                store.toggleContextPanel()
            }
            .keyboardShortcut("\\", modifiers: .command)
        }
    }
}
