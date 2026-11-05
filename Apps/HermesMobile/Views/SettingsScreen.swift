import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// Settings → the paired host, this device, and every device the host will still talk to.
///
/// A `List` with grouped styling, because that is what Settings is for on this platform:
/// native sections, native toggles, native swipe-free rows. Revoking is one-way on the
/// bridge, so the toggle is guarded by a confirmation and the row lands in a revoked
/// state rather than pretending it can be switched back on.
struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment

    @State private var allowedOverrides: [String: Bool] = [:]
    @State private var pendingRevoke: PairedDevice?
    @State private var showRevokeConfirm = false
    @State private var showUnpairConfirm = false

    var body: some View {
        List {
            hostSection
            devicesSection
            pairingSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Settings")
        .refreshable { await app.loadDevices() }
        .task { await app.loadDevices() }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
        .confirmationDialog(revokeTitle,
                            isPresented: $showRevokeConfirm,
                            titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { confirmRevoke() }
            Button("Keep access", role: .cancel) { restorePendingToggle() }
        } message: {
            Text("The host deletes this device's refresh token immediately, and any open websocket ticket stops working.")
        }
        .confirmationDialog("Unpair this phone?",
                            isPresented: $showUnpairConfirm,
                            titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task { await app.unpair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The refresh token is deleted from this phone. The device stays in the host's list until you revoke it there.")
        }
        .onChange(of: showRevokeConfirm) { presented in
            if !presented { restorePendingToggle() }
        }
    }

    // MARK: Host

    @ViewBuilder
    private var hostSection: some View {
        Section {
            if let host = app.store.host {
                hostRow(host)
                if !model.connection.isLive {
                    Button {
                        Task { await app.reconnect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.accentText)
                    }
                }
                Button(role: .destructive) {
                    showUnpairConfirm = true
                } label: {
                    Label("Unpair this phone", systemImage: "iphone.slash")
                        .font(TypeScale.font(TypeScale.md))
                }
            } else {
                Button {
                    app.isPairingPresented = true
                } label: {
                    Label("Pair a host", systemImage: "link.badge.plus")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }
            }
        } header: {
            sectionHeader("Host")
        } footer: {
            Text(app.isPaired
                 ? "Requests are signed by this device and handed to the host by `tailscale serve`."
                 : "Nothing is paired yet. Pair the phone with the bridge running on your Hermes host.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private func hostRow(_ host: PairedHost) -> some View {
        HStack(spacing: 12) {
            Avatar(host.host, size: .large, presence: model.connection.isLive ? .running : .idle)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.host)
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                Text("\(host.deviceName) · paired \(RelativeTime.short(host.pairedAt))")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            MobileConnectionPill(connection: model.connection, rttMS: app.effectiveRTT)
        }
        .padding(.vertical, 2)
    }

    // MARK: Devices

    @ViewBuilder
    private var devicesSection: some View {
        Section {
            if let error = app.devicesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.danger)
                    .padding(.vertical, 2)
            }

            ForEach(app.devices) { device in
                deviceRow(device)
            }

            if app.devices.isEmpty {
                if app.devicesLoading {
                    HStack(spacing: 8) {
                        SpinningRing(color: Tokens.textMuted, size: 11, lineWidth: 1.5)
                        Text("Loading devices…")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textMuted)
                    }
                } else {
                    Text(app.isPaired ? "The host listed no devices." : "Pair this phone to see its devices.")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textMuted)
                }
            }
        } header: {
            sectionHeader("Devices")
        } footer: {
            Text("Turning a device off revokes it on the host. That cannot be undone — pair it again to give it access.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.platform.lowercased() == "ios" ? "iphone" : "desktopcomputer")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(device.revoked ? Tokens.textDim : Tokens.textMuted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(Tokens.control)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(device.revoked ? Tokens.textDim : Tokens.textPrimary)
                        .lineLimit(1)

                    if device.deviceID == app.store.host?.deviceID {
                        StatusChip("this phone", tone: .accent, size: .small)
                    }
                }

                Text(subtitle(for: device))
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: allowedBinding(for: device))
                .labelsHidden()
                .tint(Tokens.success)
                .disabled(device.revoked || app.store.host == nil)
                .accessibilityLabel("\(device.name) has access")
                .accessibilityHint("Turning this off revokes the device on the host")
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for device: PairedDevice) -> String {
        if device.revoked { return "Revoked" }
        let platform = device.platformLabel
        if let seen = device.lastSeenAt {
            return "\(platform) · seen \(RelativeTime.short(seen))"
        }
        return platform
    }

    private func allowedBinding(for device: PairedDevice) -> Binding<Bool> {
        Binding(get: {
            allowedOverrides[device.deviceID] ?? !device.revoked
        }, set: { wantsAccess in
            guard !wantsAccess, !device.revoked else {
                allowedOverrides[device.deviceID] = nil
                return
            }
            Haptics.selection()
            allowedOverrides[device.deviceID] = false
            pendingRevoke = device
            showRevokeConfirm = true
        })
    }

    private var revokeTitle: String {
        guard let device = pendingRevoke else { return "Revoke this device?" }
        return "Revoke \(device.name)?"
    }

    private func confirmRevoke() {
        guard let device = pendingRevoke else { return }
        pendingRevoke = nil
        Task {
            await app.revoke(device)
            // Either way the override goes: a revoked row reads its own state, a failed
            // revoke reads `false` again and the toggle springs back on.
            allowedOverrides[device.deviceID] = nil
        }
    }

    private func restorePendingToggle() {
        guard let device = pendingRevoke else { return }
        allowedOverrides[device.deviceID] = nil
        pendingRevoke = nil
    }

    // MARK: Pairing / about

    private var pairingSection: some View {
        Section {
            Button {
                app.isPairingPresented = true
            } label: {
                Label("Pair a device", systemImage: "qrcode.viewfinder")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.accentText)
            }
        } footer: {
            Text("Scan the QR the host shows, or type the 8-digit code it prints. Codes are single-use and expire after two minutes.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text("0.1.0")
                    .foregroundStyle(Tokens.textGroupedSecondary)
            } label: {
                Text("Version").font(TypeScale.font(TypeScale.md))
            }

            if let host = app.store.host {
                LabeledContent {
                    Text(host.protocolVersion == 0 ? "—" : "\(host.protocolVersion)")
                        .foregroundStyle(Tokens.textGroupedSecondary)
                } label: {
                    Text("Protocol").font(TypeScale.font(TypeScale.md))
                }
            }
        } header: {
            sectionHeader("About")
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.font(TypeScale.label))
            .foregroundStyle(Tokens.textGroupedSecondary)
            .textCase(nil)
    }
}

// MARK: - Previews

#Preview("Settings · paired") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        SettingsScreen(model: environment.model)
            .navigationDestination(for: SessionID.self) { id in
                ConversationScreen(model: environment.model, sessionID: id)
            }
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Settings · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    NavigationStack {
        SettingsScreen(model: environment.model)
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
}
