import Foundation
import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI
#if canImport(UIKit)
import UIKit
#endif

/// The app's single owner of state: one `AppModel` (what the user sees) over one
/// `GatewayClient` (the wire), plus the pairing/device surface the shared model
/// deliberately does not cover.
///
/// The transport factory is built here because the socket URL is not a constant: every
/// connection (and every reconnect) has to exchange the device's refresh token for a
/// fresh 30-second ticket, so the closure reads the current credentials from
/// `CredentialBox` and asks `BridgeService` for the URL at connect time.
@MainActor
final class AppEnvironment: ObservableObject {

    let model: AppModel
    let store: HostStore

    // MARK: Pairing

    @Published var isPairingPresented = false
    @Published private(set) var isPairing = false
    @Published private(set) var pairingError: String?

    // MARK: Bots

    /// The bot switcher sheet on the Chats screen.
    @Published var isBotSwitcherPresented = false

    // MARK: Devices

    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var devicesLoading = false
    @Published private(set) var devicesError: String?

    // MARK: Host facts the shared model does not carry

    @Published private(set) var modelLabel: String?

    private let client: GatewayClientProtocol
    private let bridge: BridgeServiceProtocol
    private let box: CredentialBox

    // No default-argument values here on purpose: a default argument is evaluated in a
    // nonisolated context, and both `HostStore()` and `LiveBridgeService()` are
    // main-actor-isolated. They are built inside the body instead.
    init(client: GatewayClientProtocol? = nil,
         store: HostStore? = nil,
         bridge: BridgeServiceProtocol? = nil) {
        let store = store ?? HostStore()
        let bridge = bridge ?? LiveBridgeService()
        self.store = store
        self.bridge = bridge

        let box = CredentialBox()
        let resolvedClient: GatewayClientProtocol
        if let client {
            resolvedClient = client
        } else {
            resolvedClient = GatewayClient(makeTransport: { [box, bridge] in
                guard let credentials = await box.credentials() else {
                    throw BridgeError.noHost
                }
                let url = try await bridge.websocketURL(for: credentials.host,
                                                        refreshToken: credentials.token)
                return GatewayTransport(urlProvider: { url }).bridge()
            })
        }
        self.box = box
        self.client = resolvedClient
        self.model = AppModel(client: resolvedClient, hostName: store.host?.host ?? "hermes")
    }

    // MARK: - Derived

    /// The display name of the paired host; "hermes" until something is paired, which is
    /// what the connection banner says while unpaired.
    var hostLabel: String {
        store.host?.host ?? model.hostName
    }

    /// The bot whose sessions the Chats list is showing.
    var selectedBot: Bot? { model.selectedBot }

    /// Chrome that has room for one name (the composer placeholder, the sheet's footer).
    var selectedBotName: String {
        selectedBot?.displayName ?? model.hostName
    }

    var isPaired: Bool { store.host != nil }

    /// What the banner and the pill are allowed to say. An unpaired app is `.idle`, never
    /// "offline" — there is no host to be offline from.
    var visibleConnection: AppModel.Connection {
        store.isPaired ? model.connection : .idle
    }

    /// The header's model chip is `fixedSize`, so a long model id has to be shortened
    /// here rather than pushing the conversation title off screen.
    var modelChipLabel: String? {
        guard let label = modelLabel else { return nil }
        let words = label.split(separator: " ")
        let short = words.prefix(2).joined(separator: " ")
        guard !short.isEmpty else { return nil }
        return short.count <= 22 ? short : String(short.prefix(21)) + "…"
    }

    /// `AppModel.refreshLatency()` owns the measurement; the pill reads it, never invents
    /// a number when the host stayed silent.
    var effectiveRTT: Int? { model.latencyMS }

    var defaultDeviceName: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
        #else
        return "iOS device"
        #endif
    }

    /// `needs you` on the chats list is the session the open requests belong to.
    func needsYou(_ session: SessionSummary) -> Bool {
        !model.pendingRequests.isEmpty && model.selectedSessionID == session.id
    }

    func title(for sessionID: SessionID) -> String {
        model.sessions.first(where: { $0.id == sessionID })?.title ?? "Session"
    }

    // MARK: - Bots

    /// Re-read the host's bot directory. `AppModel.start()` already does this on connect;
    /// this is the explicit retry from the switcher and the Chats empty state. The session
    /// list is re-read too, so a directory change cannot leave another bot's rows on screen.
    func loadBots() async {
        await model.loadBots()
        await model.loadSessions()
    }

    /// Switch bots from the Chats sheet. `AppModel` owns the re-scope: it re-lists
    /// sessions for the new profile and drops the old transcript. The composer is not part
    /// of that reset, so it is emptied here rather than carried onto another bot.
    func selectBot(_ id: String) {
        guard id != model.selectedBotID else { return }
        model.draft = ""
        Task { [weak self] in
            await self?.model.selectBot(id)
        }
    }

    // MARK: - Lifecycle

    /// Boot: mirror credentials, connect if there is a host, then fill in the facts the
    /// conversation header needs. An unpaired app stays `.idle` — not "offline", which
    /// would blame a host that was never paired.
    func start() async {
        await syncCredentials()
        guard store.isPaired else { return }
        await model.start()
        await refreshModelLabel()
        await loadDevices()
        await model.refreshLatency()
    }

    func reconnect() async {
        guard store.isPaired else {
            isPairingPresented = true
            return
        }
        await syncCredentials()
        // `retryConnection` keeps the open session selected across the reconnect.
        await model.retryConnection()
        await refreshModelLabel()
        await loadDevices()
        await model.refreshLatency()
    }

    /// After pairing the session list is empty until this runs; it is also the retry
    /// path for a failed first connect.
    func syncCredentials() async {
        await box.update(host: store.host, token: store.refreshToken)
    }

    // MARK: - Pairing

    /// Redeem a code and, on success, pair, connect and load the device list.
    @discardableResult
    func pair(code rawCode: String, host rawHost: String, deviceName: String) async -> Bool {
        guard let code = PairingPayload.normalizeCode(rawCode) else {
            pairingError = "Enter the code shown on the host (digits only)."
            return false
        }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            pairingError = "Enter the host this phone should talk to."
            return false
        }

        isPairing = true
        pairingError = nil
        defer { isPairing = false }

        do {
            let claim = try await bridge.claim(code: code,
                                               host: host,
                                               deviceName: deviceName.isEmpty ? defaultDeviceName : deviceName)
            store.save(host: claim.host, refreshToken: claim.refreshToken)
            await box.update(host: claim.host, token: claim.refreshToken)
            Haptics.success()
            await model.start()
            await refreshModelLabel()
            await loadDevices()
            await model.refreshLatency()
            return true
        } catch {
            pairingError = message(for: error)
            Haptics.error()
            return false
        }
    }

    func unpair() async {
        await model.stop()
        store.clear()
        await box.update(host: nil, token: nil)
        DeviceKey.forget()
        devices = []
        devicesError = nil
        modelLabel = nil
        isBotSwitcherPresented = false
    }

    func dismissPairingError() {
        pairingError = nil
    }

    // MARK: - Devices

    func loadDevices() async {
        guard let host = store.host else {
            devices = []
            return
        }
        devicesLoading = true
        devicesError = nil
        defer { devicesLoading = false }
        do {
            devices = try await bridge.devices(for: host)
        } catch {
            // Keep the last list: a stale device list beats an empty one with a scary
            // error, and Settings shows the error above it.
            devicesError = message(for: error)
        }
    }

    func revoke(_ device: PairedDevice) async {
        guard let host = store.host else { return }
        devicesError = nil
        do {
            try await bridge.revoke(deviceID: device.deviceID, on: host)
            if let index = devices.firstIndex(where: { $0.deviceID == device.deviceID }) {
                devices[index].revoked = true
            }
            Haptics.success()
            if device.deviceID == host.deviceID {
                // Revoking the phone you are holding ends its own session: drop the
                // credentials rather than pretending the next request will work.
                await unpair()
            }
        } catch {
            devicesError = message(for: error)
            Haptics.error()
        }
    }

    // MARK: - Discovery

    /// The conversation header's model line. Failure is not fatal and is not surfaced: the
    /// header simply omits the chip.
    func refreshModelLabel() async {
        do {
            let options = try await client.modelOptions()
            if let first = options.first {
                modelLabel = first.label.isEmpty ? first.id : first.label
            }
        } catch {
            modelLabel = nil
        }
    }

    // MARK: - Errors

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Previews

    /// A fully paired, network-free environment. Screens preview against this and call
    /// `start()` in a `.task`, exactly as the app does.
    static func preview(paired: Bool = true,
                        connected: Bool = true,
                        scenario: PreviewGatewayClient.Scenario = .sessions) -> AppEnvironment {
        let environment = AppEnvironment(client: PreviewGatewayClient(scenario: scenario),
                                         store: HostStore.preview(paired: paired),
                                         bridge: PreviewBridgeService())
        if connected {
            environment.seedPreviewFacts()
        }
        return environment
    }

    /// The half of `start()`'s result that would otherwise need a live client.
    private func seedPreviewFacts() {
        modelLabel = "DeepSeek V4.1 Flash"
    }
}
