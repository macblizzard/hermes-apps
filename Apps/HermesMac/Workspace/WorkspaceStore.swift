import Combine
import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// Everything the macOS shell owns that `AppModel` does not: the pairing, the palette, the
/// pane geometry and the per-bot drafts.
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
    /// The bot whose settings sheet is open; `nil` closes it. Both the sidebar's context menu and
    /// the conversation's menu set this, so there is one sheet and one owner.
    @Published var botSettingsBot: Bot? = nil
    @Published private(set) var botIcons: [String: BotIcon] = [:]
    @Published private(set) var botIconsError: String?
    private var iconGeneration = 0
    /// The open bot's own profile default, for the header chip.
    ///
    /// `AppModel.modelLabel` is read once per connect and once per conversation open; after a bot
    /// switch it could still name the previous bot. This asks the same profile-scoped catalogue
    /// call and is refreshed whenever the open bot changes.
    @Published private(set) var openBotModelLabel: String?
    @Published private(set) var sidebarWidth: CGFloat = Geometry.sidebarDefault

    /// Set the first time the user asks to connect, so the empty sidebar can tell
    /// "not paired" apart from "paired, but nothing loaded yet".
    @Published private(set) var connectAttempted = false

    private let pairingStore = PairingStore()
    private var latencyTask: Task<Void, Never>?
    /// Unsent text per bot plus a generation token. A slow open for an older selection cannot
    /// restore its draft over the bot the user is on now.
    private var drafts = BotDraftLedger()
    /// The bot whose composer is actually attached. `nil` while a switch is still opening or when
    /// no bot has loaded yet. This is what distinguishes "the user cleared an attached draft" (a
    /// real empty composition) from "the next selection has not arrived yet" (not evidence).
    private var draftOwnerBotID: String?
    /// The target of the newest switch, even before its conversation opens. Text typed into the
    /// empty composer while that open is in flight belongs to this bot, not to the previous one.
    private var openingBotID: String?
    /// The bot whose canonical conversation this window last opened, so a reconnect does not
    /// resume the same thread a second time and interrupt what is already on screen.
    private var openedBotID: String?

    private static let widthKey = "hermes.workspace.sidebarWidth"

    // MARK: Init

    /// The real app. Reads what was paired last time, and dials nothing.
    init() {
        if let saved = PairingStore().savedAddress() {
            pairing = saved
            model = WorkspaceStore.makeModel(for: saved)
        } else {
            model = AppModel(client: UnpairedGatewayClient(), hostName: "hermes")
        }
        bindDraftCallbacks()
        restorePreferences()
    }

    /// Preview / test entry point: an `AppModel` over `PreviewGatewayClient`.
    init(model: AppModel, pairing: PairingAddress? = nil) {
        self.model = model
        self.pairing = pairing
        bindDraftCallbacks()
        restorePreferences()
    }

    /// The model may outlive a selection, so tell the draft ledger when the host actually
    /// consumed a steer. Without this, switching away while a steer is on the wire parks the
    /// words and offers them again when the user comes back, even though they were accepted.
    private func bindDraftCallbacks() {
        model.onDraftConsumed = { [weak self] botID, text in
            self?.drafts.consumeAccepted(botID: botID, text: text)
        }
        // A send can fail after the user has switched away. Restore into the bot that owned the
        // composition, not into whichever composer is visible now. The ledger refuses to replace
        // anything typed for that bot after the failure was created.
        model.onDraftRestore = { [weak self] botID, text in
            self?.drafts.restoreFailedDraft(botID: botID, text: text)
        }
    }

    // MARK: Derived

    var isPaired: Bool { pairing != nil }

    /// Under 110 pt the sidebar becomes the compact avatar strip
    /// (`Geometry.sidebarCollapseBelow`).
    var sidebarIsCompact: Bool { sidebarWidth < Geometry.sidebarCollapseBelow }

    var canSend: Bool {
        model.selectedSessionID != nil
            && !model.isStreaming
            && !model.isSteering
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.pendingAttachments.isEmpty)
    }

    /// Text in the composer while the selected bot's turn is still running. Attachments are
    /// allowed through this gate so pressing Steer surfaces the model's explanation instead of
    /// making the control look dead.
    var canSteer: Bool { model.canSteer }

    var canInterrupt: Bool { model.isStreaming || model.sending }

    var connectionLabel: String { model.connection.label }

    /// The bot whose conversation is on screen. Nil while the directory is still empty, which is
    /// what lets the sidebar say "no bots" rather than borrow a name.
    var selectedBot: Bot? { model.selectedBot }

    /// The sidebar header. A bot name when one is selected; the host's own name before
    /// profiles arrive, never a hardcoded product name.
    var botTitle: String {
        selectedBot?.displayName ?? model.hostName
    }

    /// Open one bot's settings, from wherever the user asked for it.
    func openBotSettings(_ bot: Bot) {
        botSettingsBot = bot
    }

    /// Ask the host for the open bot's current model, scoped to that profile.
    ///
    /// Silent on failure: no chip is honest, a stale or gateway-wide model name is the bug this
    /// replaces. Called when the workspace appears, when the bot changes, and after a settings write.
    func refreshOpenBotModelLabel() async {
        guard let id = model.selectedBotID else {
            openBotModelLabel = nil
            return
        }
        do {
            openBotModelLabel = try await model.modelCatalog(for: id).current?.label
        } catch {
            openBotModelLabel = nil
        }
    }

    // MARK: Bots

    /// Re-read the host's bot directory. `AppModel.start()` already does this on connect;
    /// this exists for the explicit "check again" affordance, which must not reconnect.
    ///
    /// The session list is re-read too: if the selected bot disappeared from the directory,
    /// `loadBots` moves the selection, and the rows on screen would otherwise still belong
    /// to the bot that is no longer selected.
    func loadBots() async {
        await model.loadBots()
        await loadBotIcons()
        await openSelectedBotConversation()
    }

    /// Switch the workspace to another bot and open its one shared conversation.
    ///
    /// The composer is per-bot state the model does not clear on a switch, so the draft is parked
    /// under the bot it was typed for and the field is emptied. The conversation itself comes from
    /// `AppModel.endlessSession`, which opens only the host's exact-title canonical row and creates
    /// a fresh one when it is absent. This method never invents a device-local thread or adopts an
    /// unrelated session.
    func selectBot(_ id: String) {
        guard id != model.selectedBotID else { return }
        // The composer belongs to the attached bot, or to the target of an open that has not
        // finished yet. `model.selectedBotID` alone is not enough: a rapid second selection can
        // arrive before the first one's open has updated it.
        let source = openingBotID ?? draftOwnerBotID ?? model.selectedBotID
        let sourceIsAttached = openingBotID == nil && draftOwnerBotID == source
        let token = drafts.beginSwitch(from: source, draft: model.draft,
                                       replacingParkedDraft: sourceIsAttached)
        model.draft = ""
        draftOwnerBotID = nil
        openingBotID = id
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.model.endlessSession(for: id)
            // A newer switch owns the screen now: neither its bot nor its draft may be replaced
            // by this slower answer.
            guard self.drafts.isCurrent(token), self.model.selectedBotID == id else { return }
            if self.openingBotID == id { self.openingBotID = nil }
            // A failed open keeps the parked draft for the next visit; it must not be called the
            // opened bot if there is no conversation to attach.
            guard opened != nil else { return }
            self.openedBotID = id
            self.draftOwnerBotID = id
            // The chip names the bot on screen: re-read that bot's own default.
            await self.refreshOpenBotModelLabel()
            guard self.drafts.isCurrent(token), self.model.selectedBotID == id else { return }
            // Do not overwrite text typed while the conversation was opening.
            guard self.model.draft.isEmpty,
                  let restored = self.drafts.draft(for: id, token: token),
                  !restored.isEmpty else { return }
            self.model.draft = restored
        }
    }

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
            await loadBotIcons()
            await openSelectedBotConversation()
        }
    }

    func reconnect() async {
        connectAttempted = true
        await model.retryConnection()
        if model.connection.isLive {
            startLatencyLoop()
            await loadBotIcons()
            await openSelectedBotConversation()
        }
    }

    func disconnect() async {
        clearBotIcons()
        stopLatencyLoop()
        await model.stop()
    }

    /// Persist a new host and rebuild the model around it. Does not connect: the sheet
    /// calls `connect()` straight after, which is the user's deliberate second half.
    func pair(urlText: String, deviceID: String = "", token: String) throws {
        let address = try PairingAddress.parse(urlText, deviceID: deviceID, token: token)
        pairingStore.save(address)

        clearBotIcons()
        stopLatencyLoop()
        pairing = address
        model = WorkspaceStore.makeModel(for: address)
        bindDraftCallbacks()
        drafts.removeAll()
        draftOwnerBotID = nil
        openingBotID = nil
        openedBotID = nil
        connectAttempted = false
        isPairSheetPresented = false
    }

    /// True when the keychain refused the pairing, so the sheet can say the host will have
    /// to be re-paired after a relaunch.
    var pairingIsSessionOnly: Bool { !pairingStore.persisted && pairing != nil }

    func unpair() async {
        clearBotIcons()
        stopLatencyLoop()
        await model.stop()
        pairingStore.clear()
        pairing = nil
        model = AppModel(client: UnpairedGatewayClient(), hostName: "hermes")
        bindDraftCallbacks()
        drafts.removeAll()
        draftOwnerBotID = nil
        openingBotID = nil
        openedBotID = nil
        connectAttempted = false
    }

    private func clearBotIcons() {
        iconGeneration += 1
        botIcons = [:]
        botIconsError = nil
    }

    func loadBotIcons() async {
        guard let address = pairing, !address.isTicketOnly else { return }
        iconGeneration += 1
        let generation = iconGeneration
        do {
            let icons = try await MacBotIconService(address: address).load()
            guard generation == iconGeneration, pairing == address else { return }
            botIcons = icons
            botIconsError = nil
        } catch {
            guard generation == iconGeneration, pairing == address else { return }
            botIconsError = error.localizedDescription
        }
    }

    func saveBotIcon(botID: String, icon: BotIcon?) async throws {
        guard let address = pairing, !address.isTicketOnly else {
            throw MacBotIconService.Failure.devicePairingRequired
        }
        iconGeneration += 1
        let generation = iconGeneration
        try await MacBotIconService(address: address).save(botID: botID, icon: icon)
        guard generation == iconGeneration, pairing == address else { return }
        await loadBotIcons()
        if let error = botIconsError {
            throw MacBotIconService.Failure.refresh(error)
        }
    }

    // MARK: Conversation

    /// Open the selected bot's host-canonical conversation if this window has not already done so.
    func openSelectedBotConversation(force: Bool = false) async {
        guard model.connection.isLive, let bot = model.selectedBotID else { return }
        guard force || openedBotID != bot || model.selectedSessionID == nil else { return }
        let token = drafts.currentToken
        let opened = await model.endlessSession(for: bot)
        // The selection changed while the conversation was opening. Do not claim this bot as
        // opened and do not write its draft over the current one.
        guard drafts.isCurrent(token), model.selectedBotID == bot else { return }
        guard opened != nil else { return }
        openedBotID = bot
        draftOwnerBotID = bot
        // Only restore parked text into an untouched composer; newer typing wins.
        guard model.draft.isEmpty,
              let restored = drafts.draft(for: bot, token: token),
              !restored.isEmpty else { return }
        model.draft = restored
    }

    // MARK: Turn

    func send() {
        guard canSend else { return }
        Task { [weak self] in
            await self?.model.send()
        }
    }

    func steer() {
        guard canSteer else { return }
        Task { [weak self] in
            await self?.model.steer()
        }
    }

    func interrupt() {
        guard canInterrupt else { return }
        Task { [weak self] in
            await self?.model.interrupt()
        }
    }

    func retrySend() {
        if model.isStreaming {
            steer()
        } else {
            send()
        }
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

    // MARK: Palette

    func openPalette() { isPalettePresented = true }
    func closePalette() { isPalettePresented = false }

    /// The live catalogue. Disabled entries are shown but cannot run: a palette that hides
    /// half its verbs is harder to learn than one that explains why a verb is unavailable.
    var commands: [WorkspaceCommand] {
        var items: [WorkspaceCommand] = []

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
            id: "turn.steer",
            title: "Steer the running turn",
            subtitle: "Send the composer text into the current turn",
            systemImage: "arrow.up.circle",
            shortcut: nil,
            group: .session,
            isEnabled: canSteer,
            run: { [weak self] in self?.steer() }))

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
            id: "bot.settings",
            title: "Bot settings…",
            subtitle: selectedBot.map { "Icon, description and model for \($0.displayName)" }
                ?? "Select a bot first",
            systemImage: "gearshape",
            shortcut: nil,
            group: .bot,
            isEnabled: selectedBot != nil,
            run: { [weak self] in
                guard let self, let bot = self.selectedBot else { return }
                self.openBotSettings(bot)
            }))

        items.append(WorkspaceCommand(
            id: "view.sidebar",
            title: sidebarIsCompact ? "Expand bot list" : "Collapse bot list",
            subtitle: "Switch between the full names and the 88 pt icon strip",
            systemImage: "sidebar.left",
            shortcut: nil,
            group: .view,
            isEnabled: true,
            run: { [weak self] in
                guard let self else { return }
                self.setSidebarWidth(self.sidebarIsCompact ? Geometry.sidebarDefault : Geometry.sidebarCompact)
                self.endSidebarDrag()
            }))

        // The bots are a catalogue of their own: one command per profile, disabled for the
        // one already on screen, so switching is reachable without leaving the keyboard.
        // `orderedBots` is the same list the sidebar draws — pinned first, hidden ones absent.
        for bot in model.orderedBots {
            items.append(WorkspaceCommand(
                id: "bot.\(bot.id)",
                title: "Switch to \(bot.displayName)",
                subtitle: bot.id == model.selectedBotID
                    ? "Current bot · \(bot.id)"
                    : "Bot · \(bot.id)",
                systemImage: "person.crop.circle",
                shortcut: nil,
                group: .bot,
                isEnabled: bot.id != model.selectedBotID && model.connection.isLive,
                run: { [weak self] in self?.selectBot(bot.id) }))
        }

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
