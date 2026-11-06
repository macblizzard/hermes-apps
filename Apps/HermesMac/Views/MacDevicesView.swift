import SwiftUI

/// Management uses its own window so it is available even while the socket is disconnected.
struct MacDevicesView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var devices: [MacPairedDevice] = []
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pending: MacPairedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paired Devices").font(.title2.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }
                    .disabled(busy || store.pairing == nil || store.pairing?.isTicketOnly == true)
            }
            if let address = store.pairing {
                Text("Devices on \(address.displayHost)").foregroundStyle(.secondary)
                if address.isTicketOnly {
                    Text("Device management requires a device ID and refresh token. Pair this Mac as a device first.")
                        .foregroundStyle(.secondary)
                } else {
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    if devices.isEmpty && !busy && error == nil && notice == nil {
                        Text("No devices found.").foregroundStyle(.secondary)
                    }
                    List(devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name + (device.deviceID == address.deviceID ? " (This Mac)" : ""))
                                    .fontWeight(.medium)
                                Text("\(device.platform) · \(device.revoked ? "Revoked" : "Active")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(device.deviceID).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button(device.revoked ? "Remove…" : "Revoke…") { pending = device }
                                .disabled(busy)
                        }.padding(.vertical, 4)
                    }
                }
            } else {
                Text("Pair a host before managing devices.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .task(id: store.pairing) { await refresh() }
        .confirmationDialog(pending?.revoked == true ? "Permanently remove device?" : "Revoke device?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { device in
            Button(device.revoked ? "Permanently Remove" : "Revoke", role: .destructive) {
                pending = nil
                Task { await perform(device) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { device in
            if device.revoked {
                Text("Permanently remove \(device.name) from the host's device list? This cannot be undone.")
            } else if device.deviceID == store.pairing?.deviceID {
                Text("Revoke this Mac? Its connection will close and you will need to pair again to manage devices.")
            } else {
                Text("Revoke \(device.name)? It will be disconnected and must pair again to regain access.")
            }
        }
    }

    @MainActor private func refresh() async {
        guard let address = store.pairing, !address.isTicketOnly else {
            devices = []; error = nil; notice = nil; busy = false; return
        }
        busy = true; error = nil; notice = nil
        defer { if store.pairing == address { busy = false } }
        do {
            let result = try await MacDeviceService(address: address).devices()
            guard !Task.isCancelled, store.pairing == address else { return }
            devices = result
        } catch {
            guard !Task.isCancelled, store.pairing == address else { return }
            devices = []; self.error = "Could not load devices: \(error.localizedDescription)"
        }
    }

    @MainActor private func perform(_ device: MacPairedDevice) async {
        guard let address = store.pairing else { return }
        busy = true; error = nil; notice = nil
        do {
            let service = MacDeviceService(address: address)
            if device.revoked { try await service.removeRevoked(device.deviceID) }
            else { try await service.revoke(device.deviceID) }
            guard store.pairing == address else { busy = false; return }
            if !device.revoked && device.deviceID == address.deviceID {
                devices = []
                notice = "This Mac was revoked. Pair it again to manage devices."
                busy = false
            } else {
                busy = false
                await refresh()
            }
        } catch {
            guard store.pairing == address else { busy = false; return }
            busy = false
            self.error = "Could not \(device.revoked ? "remove" : "revoke") device: \(error.localizedDescription)"
        }
    }
}
