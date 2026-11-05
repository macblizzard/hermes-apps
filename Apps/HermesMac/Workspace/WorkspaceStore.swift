import Combine
import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// Everything the macOS shell owns that `AppModel` does not: the pairing, the palette, the
/// pane geometry and the per-session drafts.
///
/// `AppModel` stays the single source of truth for what is on the wire. This type is the
/// window around it — and it is deliberately the only place that knows both a
/// `PairingAddress` and a `GatewayClient`, so a preview can hold an `AppModel` with no
/// socket anywhere near it.
@MainActor
final class WorkspaceStore: ObservableObject {

    // MARK: State

    /// The per-window model. Replaced when the host changes; never mutated from outside.
    @Published private(set) var model: AppModel
    @Published private(set) var pairing: PairingAddress? = nil

    @Published var isPairSheetPresented = false
    @Published var isPalettePresented = false
    @Published var searchText = ""
    @Published var showsContextPanel = true
    @Published private(set) var sidebarWidth: CGFloat = Geometry.sidebarDefault

    /// Set the first time the user asks to connect, so the empty sidebar can tell
    /// "not paired" apart from "paired, but nothing loaded yet".
    @Published private(set) var connectAttempted = false

    private let pairingStore = PairingStore()
    private var latencyTask: Task<Void, Never>?
    private var drafts: [SessionID: String] = [:]

    private static let widthKey = "hermes.workspace.sidebarWidth"
    private static let contextKey = "hermes.workspace.showsContext"

    // MARK: Init

    /// The real app. Reads what was paired last time, and dials nothing.
    init() {
        if let saved = PairingStore().savedAddress() {
            pairing = saved
            model = WorkspaceStore.makeModel(for: saved)
        } else {
            model = AppModel(client: UnpairedGatewayClient(), hostName: "hermes")
        }
        restorePreferences()
    }

    /// Preview / test entry point: an `AppModel` over `PreviewGatewayClient`.
    init(model: AppModel, pairing: PairingAddress? = nil) {
        self.model = model
        self.pairing = pairing
        restorePreferences()
    }

    // MARK: Derived

    var isPaired: Bool { pairing != nil }

    /// Under 110 pt the sidebar becomes the compact avatar strip
    /// (`Geometry.sidebarCollapseBelow`).
    var sidebarIsCompact: Bool { sidebarWidth < Geometry.sidebarCollapseBelow }

    var canSend: Bool {
        model.selectedSessionID != nil
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canInterrupt: Bool { model.isStreaming || model.sending }

    var connectionLabel: String { model.connection.label }

    // MARK: Lifecycle

    /// Attach to the host. Only ever called from an explicit user action — the app makes
    /// no network call at launch.
    func connect() async {
        guard pairing != nil else {
            isPairSheetPresented = true
            return
        }
        connectAttempted = true
        await model.start()
        if model.connection.isLive {
            startLatencyLoop()
            await openFirstSessionIfNeeded()
        }
    }

    func reconnect() async {
        connectAttempted = true
        await model.retryConnection()
        if model.connection.isLive {
            startLatencyLoop()
        }
    }

    func disconnect() async {
        stopLatencyLoop()
        await model.stop()
    }

    /// Persist a new host and rebuild the model around it. Does not connect: the sheet
    /// calls `connect()` straight after, which is the user's deliberate second half.
    func pair(urlText: String, deviceID: String = "", token: String) throws {
        let address = try PairingAddress.parse(urlText, deviceID: deviceID, token: token)
        pairingStore.save(address)

        stopLatencyLoop()
        pairing = address
        model = WorkspaceStore.makeModel(for: address)
        drafts.removeAll()
        connectAttempted = false
        isPairSheetPresented = false
    }

    /// True when the keychain refused the pairing, so the sheet can say the host will have
    /// to be re-paired after a relaunch.
    var pairingIsSessionOnly: Bool { !pairingStore.persisted && pairing != nil }

    func unpair() async {
        stopLatencyLoop()
        await model.stop()
        pairingStore.clear()
        pairing = nil
        model = AppModel(client: UnpairedGatewayClient(), hostName: "hermes")
        drafts.removeAll()
        connectAttempted = false
    }

    // MARK: Sessions

    /// Open a session, keeping each session's unsent draft with it.
    func select(_ id: SessionID) {
        guard id != model.selectedSessionID else { return }
        if let current = model.selectedSessionID {
            drafts[current] = model.draft
        }
        let restored = drafts[id] ?? ""
        Task { [weak self] in
            guard let self else { return }
            await self.model.select(id)
            self.model.draft = restored
        }
    }

    func openFirstSessionIfNeeded() async {
        guard model.selectedSessionID == nil, let first = model.sessions.first else { return }
        await model.select(first.id)
    }

    func reloadSessions() {
        Task { [weak self] in
            await self?.model.loadSessions()
        }
    }

    func newSession() {
        Task { [weak self] in
            guard let self else { return }
            await self.model.newSession()
            if let id = self.model.selectedSessionID {
                self.drafts[id] = ""
            }
        }
    }

    // MARK: Turn

    func send() {
        guard canSend else { return }
        Task { [weak self] in
            await self?.model.send()
        }
    }

    func interrupt() {
        guard canInterrupt else { return }
        Task { [weak self] in
            await self?.model.interrupt()
        }
    }

    func retrySend() {
        guard canSend else { return }
        send()
    }

    // MARK: Approvals

    func approve(_ request: ServerRequest) {
        Task { [weak self] in
            await self?.model.approve(request)
        }
    }

    /// Deny is an explicit `deny` choice, never a `-32601`: the latter tells the gateway this
    /// client cannot answer at all, and the agent is told nobody refused.
    func deny(_ request: ServerRequest) {
        Task { [weak self] in
            await self?.model.deny(request)
        }
    }

    func answer(_ request: ServerRequest, choice: String) {
        Task { [weak self] in
            await self?.model.answer(request, choice: choice)
        }
    }

    func submitClarification(_ request: ServerRequest, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            await self?.model.answers(request, ["response": trimmed])
        }
    }

    func decline(_ request: ServerRequest) {
        Task { [weak self] in
            await self?.model.decline(request)
        }
    }

    // MARK: Geometry

    /// Live drag value, clamped to what the layout can actually draw (the collapse rule
    /// needs values under 110 to be reachable, so the floor is lower than `sidebarMin`).
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(Geometry.sidebarMax, max(64, width))
    }

    /// Snap on mouse-up: under 110 collapses to the 88 pt strip, otherwise the 128…400
    /// range applies. Persisted so the window reopens where it was left.
    func endSidebarDrag() {
        if sidebarWidth < Geometry.sidebarCollapseBelow {
            sidebarWidth = Geometry.sidebarCompact
        } else {
            sidebarWidth = min(Geometry.sidebarMax, max(Geometry.sidebarMin, sidebarWidth))
        }
        UserDefaults.standard.set(Double(sidebarWidth), forKey: WorkspaceStore.widthKey)
    }

    func toggleContextPanel() {
        showsContextPanel.toggle()
        UserDefaults.standard.set(showsContextPanel, forKey: WorkspaceStore.contextKey)
    }

    // MARK: Palette

    func openPalette() { isPalettePresented = true }
    func closePalette() { isPalettePresented = false }

    /// The live catalogue. Disabled entries are shown but cannot run: a palette that hides
    /// half its verbs is harder to learn than one that explains why a verb is unavailable.
    var commands: [WorkspaceCommand] {
        var items: [WorkspaceCommand] = []

        items.append(WorkspaceCommand(
            id: "session.new",
            title: "New session",
            subtitle: "Ask the host for a fresh conversation",
            systemImage: "plus.bubble",
            shortcut: "⌘N",
            group: .session,
            isEnabled: model.connection.isLive,
            run: { [weak self] in self?.newSession() }))

        items.append(WorkspaceCommand(
            id: "session.reload",
            title: "Reload sessions",
            subtitle: "Re-list conversations on the host",
            systemImage: "arrow.clockwise",
            shortcut: nil,
            group: .session,
            isEnabled: model.connection.isLive,
            run: { [weak self] in self?.reloadSessions() }))

        items.append(WorkspaceCommand(
            id: "turn.interrupt",
            title: "Interrupt the turn",
            subtitle: "Stop the running agent turn on this session",
            systemImage: "stop.fill",
            shortcut: "⌘.",
            group: .session,
            isEnabled: canInterrupt,
            run: { [weak self] in self?.interrupt() }))

        items.append(WorkspaceCommand(
            id: "host.connect",
            title: model.connection.isLive ? "Reconnect to host" : "Connect to host",
            subtitle: pairing.map { "Open the socket to \($0.displayHost)" } ?? "No host paired yet",
            systemImage: "bolt.horizontal",
            shortcut: "⌘R",
            group: .host,
            isEnabled: isPaired,
            run: { [weak self] in
                guard let self else { return }
                Task {
                    if self.model.connection.isLive {
                        await self.reconnect()
                    } else {
                        await self.connect()
                    }
                }
            }))

        items.append(WorkspaceCommand(
            id: "host.disconnect",
            title: "Disconnect",
            subtitle: "Close the socket and keep the pairing",
            systemImage: "bolt.slash",
            shortcut: nil,
            group: .host,
            isEnabled: model.connection.isLive,
            run: { [weak self] in
                guard let self else { return }
                Task { await self.disconnect() }
            }))

        items.append(WorkspaceCommand(
            id: "host.pair",
            title: "Pair host…",
            subtitle: "Enter a wss:// URL and a device token",
            systemImage: "link",
            shortcut: "⇧⌘P",
            group: .host,
            isEnabled: true,
            run: { [weak self] in self?.isPairSheetPresented = true }))

        items.append(WorkspaceCommand(
            id: "view.context",
            title: showsContextPanel ? "Hide context panel" : "Show context panel",
            subtitle: "The \(Int(Geometry.contextPanel)) pt column on the right",
            systemImage: showsContextPanel ? "sidebar.right" : "sidebar.left",
            shortcut: "⌘\\",
            group: .view,
            isEnabled: true,
            run: { [weak self] in self?.toggleContextPanel() }))

        items.append(WorkspaceCommand(
            id: "view.sidebar",
            title: sidebarIsCompact ? "Expand session list" : "Collapse session list",
            subtitle: "Switch between the 280 pt list and the 88 pt strip",
            systemImage: "sidebar.left",
            shortcut: nil,
            group: .view,
            isEnabled: true,
            run: { [weak self] in
                guard let self else { return }
                self.setSidebarWidth(self.sidebarIsCompact ? Geometry.sidebarDefault : Geometry.sidebarCompact)
                self.endSidebarDrag()
            }))

        return items
    }

    // MARK: Private

    private func startLatencyLoop() {
        stopLatencyLoop()
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.model.refreshLatency()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func stopLatencyLoop() {
        latencyTask?.cancel()
        latencyTask = nil
    }

    private func restorePreferences() {
        let saved = UserDefaults.standard.double(forKey: WorkspaceStore.widthKey)
        if saved > 0 {
            sidebarWidth = min(Geometry.sidebarMax, max(Geometry.sidebarCompact, CGFloat(saved)))
        }
        if UserDefaults.standard.object(forKey: WorkspaceStore.contextKey) != nil {
            showsContextPanel = UserDefaults.standard.bool(forKey: WorkspaceStore.contextKey)
        }
    }

    /// The one place a real socket is built.
    ///
    /// The transport factory is async and runs once per connection attempt, which is exactly
    /// what the ticket flow needs: **each** attempt mints a fresh single-use ticket, so a
    /// reconnect after a drop does not replay a burned one.
    private static func makeModel(for address: PairingAddress) -> AppModel {
        let client = GatewayClient(makeTransport: {
            let socketURL = try await address.socketURL()
            let transport = GatewayTransport(urlProvider: { socketURL })
            return transport.bridge()
        })
        return AppModel(client: client, hostName: address.displayHost)
    }
}
