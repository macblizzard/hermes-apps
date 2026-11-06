import HermesAppKit
import OpenBotUI
import SwiftUI

/// macOS workspace. Bot list on the left (280 pt, drag 64…400, collapsing to an 88 pt icon
/// strip) and the selected bot's one conversation on the right. There is no session browser,
/// session search field, host-status block or right context panel.
///
/// Launch is offline by construction: `WorkspaceStore` restores the pairing it was given
/// last time but dials nothing, and the only calls into `connect()` are the Connect button,
/// the palette's verb and the pair sheet's Pair press. Pairing, device management and the
/// selected bot's settings are also in the native menu bar.
@main
struct HermesMacApp: App {
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup("Hermes") {
            WorkspaceRoot(store: store)
                .frame(minWidth: Geometry.sidebarMin + Geometry.conversationMin,
                       minHeight: 560)
                .preferredColorScheme(.dark)
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
            Button("Pair Host…") {
                store.isPairSheetPresented = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Manage Paired Devices…") {
                openWindow(id: "paired-devices")
            }
        }

        CommandMenu("Bot") {
            Button("Bot Settings…") {
                if let bot = store.selectedBot {
                    store.openBotSettings(bot)
                }
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(store.selectedBot == nil)

            Divider()

            ForEach(store.model.orderedBots) { bot in
                Button(bot.id == store.model.selectedBotID
                       ? "✓ \(bot.displayName)"
                       : bot.displayName) {
                    store.selectBot(bot.id)
                }
                .disabled(bot.id == store.model.selectedBotID || !store.model.connection.isLive)
            }
        }

        CommandMenu("Session") {
            Button(store.model.isStreaming ? "Steer Turn" : "Send Message") {
                if store.model.isStreaming {
                    store.steer()
                } else {
                    store.send()
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store.model.isStreaming ? !store.canSteer : !store.canSend)

            Button("Interrupt Turn") {
                store.interrupt()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!store.canInterrupt)

            Divider()

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
    }
}
