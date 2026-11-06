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

    /// The chip's own width. Below the inline floor the two or three verbs cannot fit on one
    /// line at the 200 pt panel floor, so they fold into one overflow menu instead of
    /// truncating to initials.
    @State private var chipWidth: CGFloat = 0
    private static let inlineActionFloor: CGFloat = 240

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
                        .font(TypeScale.font(TypeScale.caption))
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
                        .font(Tokens.mono)
                        .foregroundStyle(Tokens.textDim)

                    Spacer(minLength: 0)

                    if model.hasPendingRequests {
                        Text("\(model.pendingRequests.count) waiting")
                            .font(TypeScale.font(TypeScale.caption, weight: .medium))
                            .foregroundStyle(Tokens.warning)
                    }
                }
            }

            action
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ChipWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ChipWidthKey.self) { width in
            if width != chipWidth { chipWidth = width }
        }
        .padding(.horizontal, Geometry.sidebarInset)
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
        if chipWidth > 0, chipWidth < Self.inlineActionFloor {
            overflowAction
        } else {
            inlineAction
        }
    }

    /// One menu holding whichever verbs the current state offers, for the narrow panel.
    private var overflowAction: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Menu {
                if !store.isPaired {
                    Button("Pair host…") { store.isPairSheetPresented = true }
                } else if model.connection.isLive {
                    Button("Reconnect") { Task { await store.reconnect() } }
                    Button("Disconnect") { Task { await store.disconnect() } }
                    Divider()
                    Button("Pair another host…") { store.isPairSheetPresented = true }
                } else {
                    Button("Connect") { Task { await store.connect() } }
                        .disabled(model.connection == .connecting)
                    Divider()
                    Button("Pair host…") { store.isPairSheetPresented = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Connection actions")
            .accessibilityLabel("Connection actions")
        }
    }

    @ViewBuilder
    private var inlineAction: some View {
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

/// The chip's measured width, for the inline/overflow decision.
private struct ChipWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
