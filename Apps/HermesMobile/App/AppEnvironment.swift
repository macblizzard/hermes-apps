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

    /// Set by Settings → Disconnect. The app reconnects a dead socket on its own when it
    /// returns to the foreground; a socket the user closed on purpose is not dead, so this
    /// keeps the scene-phase retry from silently undoing that choice.
    @Published private(set) var isDisconnectedByUser = false

    // MARK: Devices

    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var devicesLoading = false
    @Published private(set) var devicesError: String?

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
        self.model = AppModel(client: resolvedClient, hostName: store.host?.host ?? "hermes")
    }

    // MARK: - Derived

    /// The display name of the paired host; "hermes" until something is paired, which is
    /// what the connection banner says while unpaired.
    var hostLabel: String {
        store.host?.host ?? model.hostName
    }

    var isPaired: Bool { store.host != nil }

    /// What the banner and the pill are allowed to say. An unpaired app is `.idle`, never
    /// "offline" — there is no host to be offline from.
    var visibleConnection: AppModel.Connection {
        store.isPaired ? model.connection : .idle
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

    // MARK: - Bots

    /// Re-read the host's bot directory. `AppModel.start()` already does this on connect;
    /// this is the explicit retry behind pull-to-refresh and the list's empty state. Bots
    /// are the only thing this app lists now — there is no session list to keep in step.
    func loadBots() async {
        await model.loadBots()
    }

    // MARK: - Lifecycle

    /// Boot: mirror credentials, connect if there is a host, then fill in the facts the
    /// conversation header needs. An unpaired app stays `.idle` — not "offline", which
    /// would blame a host that was never paired.
    func start() async {
        await syncCredentials()
        guard store.isPaired else { return }
        isDisconnectedByUser = false
        await model.start()
        await loadDevices()
        await model.refreshLatency()
    }

    func reconnect() async {
        guard store.isPaired else {
            isPairingPresented = true
            return
        }
        isDisconnectedByUser = false
        await syncCredentials()
        // `retryConnection` keeps the open session selected across the reconnect.
        await model.retryConnection()
        await loadDevices()
        await model.refreshLatency()
    }

    /// The transport reads credentials at connect time, so they are mirrored here before
    /// every connect; this is also the retry path for a first connect that failed.
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
            isDisconnectedByUser = false
            await model.start()
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
    }

    /// Drop the socket but keep the pairing: the refresh token stays on this phone, so
    /// `reconnect()` can bring the same host back without another QR code. Settings offers
    /// this next to *Re-pair*, which is the action that replaces the credentials.
    func disconnect() async {
        isDisconnectedByUser = true
        await model.stop()
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

    // MARK: - Errors

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Previews

    /// A fully paired, network-free environment. Screens preview against this and call
    /// `start()` in a `.task`, exactly as the app does.
    static func preview(paired: Bool = true,
                        scenario: PreviewGatewayClient.Scenario = .sessions) -> AppEnvironment {
        AppEnvironment(client: PreviewGatewayClient(scenario: scenario),
                       store: HostStore.preview(paired: paired),
                       bridge: PreviewBridgeService())
    }
}
