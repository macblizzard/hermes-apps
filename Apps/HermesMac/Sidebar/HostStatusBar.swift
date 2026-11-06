import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The machine chip at the foot of the sidebar: which host, whether the wire is up, and
/// how long a round trip takes right now.
///
/// One chip carries the transport and the latency together (`StatusChip.transport`), and
/// the button under it is the only place the app dials out from the sidebar. When nothing
/// is paired the same slot offers pairing instead of a dead toggle.
struct HostStatusBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var hostName: String {
        store.pairing?.displayHost ?? model.hostName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(hostName, size: .small, presence: presence)

                VStack(alignment: .leading, spacing: 1) {
                    Text(hostName)
                        .font(TypeScale.font(Tokens.textMD, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)

                    Text(model.connection.detail)
                        .font(TypeScale.font(10))
                        .foregroundStyle(model.connection.isLive ? Tokens.textMuted : Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                StatusChip.transport(model.connection.transportState,
                                     path: .direct,
                                     rttMS: model.latencyMS)
            }

            if model.connection.isLive {
                HStack(spacing: 6) {
                    Text(latencyText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Tokens.textDim)

                    Spacer(minLength: 0)

                    if model.hasPendingRequests {
                        Text("\(model.pendingRequests.count) waiting")
                            .font(TypeScale.font(10, weight: .medium))
                            .foregroundStyle(Tokens.warning)
                    }
                }
            }

            action
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var presence: Avatar.Presence {
        if model.hasPendingRequests { return .needsYou }
        if model.connection.isLive { return .running }
        return .idle
    }

    private var latencyText: String {
        if let ms = model.latencyMS {
            return "rtt \(ms) ms"
        }
        return "rtt not measured"
    }

    @ViewBuilder
    private var action: some View {
        if !store.isPaired {
            OpenBotButton("Pair host",
                          systemImage: "link",
                          kind: .secondary,
                          size: .small,
                          corners: .rounded) {
                store.isPairSheetPresented = true
            }
        } else if model.connection.isLive {
            HStack(spacing: 6) {
                OpenBotButton("Disconnect", kind: .ghost, size: .small) {
                    Task { await store.disconnect() }
                }
                Spacer(minLength: 0)
                OpenBotIconButton("link", label: "Pair host…", size: .small) {
                    store.isPairSheetPresented = true
                }
                OpenBotButton("Reconnect", kind: .secondary, size: .small) {
                    Task { await store.reconnect() }
                }
            }
        } else {
            HStack(spacing: 6) {
                OpenBotButton("Connect",
                              systemImage: "bolt.horizontal",
                              kind: .primary,
                              size: .small,
                              isBusy: model.connection == .connecting) {
                    Task { await store.connect() }
                }
                Spacer(minLength: 0)
                OpenBotButton("Pair…", kind: .ghost, size: .small) {
                    store.isPairSheetPresented = true
                }
            }
        }
    }
}

// MARK: - Previews

private struct HostStatusBarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        VStack(spacing: 12) {
            HostStatusBar(model: store.model, store: store)
        }
        .frame(width: 280)
        .background(Tokens.sidebar)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#Preview("Host status bar") {
    HostStatusBarPreview()
}
