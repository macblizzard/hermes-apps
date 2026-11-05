import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

// TODO(design-system): the context panel's key/value row is local — OpenBotUI has cards and
// grouped rows, but not the 236 pt inspector row this pane is built from.

/// The right-hand inspector: the session's facts, the wire's facts, and the turn's state.
///
/// Everything here is read from `AppModel`; nothing is estimated. Where the protocol does
/// not report something yet (token usage, skills in play) the pane says so in one line
/// instead of drawing a gauge fed by a guess — a number that is wrong is worse than a
/// sentence that is honest.
struct ContextPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                sessionSection
                Hairline()
                connectionSection
                Hairline()
                turnSection
                Hairline()
                contextSection
                Hairline()
                skillsSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .frame(width: Geometry.contextPanel)
        .background(Tokens.sidebar)
    }

    // MARK: Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaption("SESSION")

            MacContextRow(label: "Host", value: model.hostName)

            if let session = model.selectedSession {
                MacContextRow(label: "Title", value: session.title, truncates: true)
                if let updated = session.updatedAt {
                    MacContextRow(label: "Updated", value: RelativeTime.detailed(updated))
                }
            } else {
                MacContextRow(label: "Title", value: "none open")
            }

            MacContextRow(label: "Entries", value: "\(model.transcript.count)")

            if let id = model.selectedSessionID {
                MacContextRow(label: "ID", value: String(id.prefix(14)), mono: true)
            }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaption("CONNECTION")

            HStack(spacing: 6) {
                Text("State")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                Spacer(minLength: 6)
                StatusChip.transport(model.connection.transportState,
                                     path: .direct,
                                     rttMS: model.latencyMS)
            }

            MacContextRow(label: "Latency",
                          value: model.latencyMS.map { "\($0) ms" } ?? "not measured",
                          mono: true)

            MacContextRow(label: "Endpoint",
                          value: store.pairing?.baseURL ?? "not paired",
                          mono: true,
                          truncates: true)

            if let error = model.lastSendError {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if model.connection.isLive {
                    OpenBotButton("Disconnect", kind: .ghost, size: .small) {
                        Task { await store.disconnect() }
                    }
                } else {
                    OpenBotButton("Connect",
                                  kind: .secondary,
                                  size: .small,
                                  isDisabled: !store.isPaired,
                                  isBusy: model.connection == .connecting) {
                        Task { await store.connect() }
                    }
                }

                Spacer(minLength: 0)

                OpenBotButton("Pair…", kind: .ghost, size: .small) {
                    store.isPairSheetPresented = true
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Turn

    private var turnSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaption("TURN")

            HStack(spacing: 6) {
                Text("State")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                Spacer(minLength: 6)
                if model.isStreaming {
                    StatusChip("streaming", tone: .success, showsDot: true, size: .small)
                } else if model.hasPendingRequests {
                    StatusChip("blocked", tone: .warning, showsDot: true, size: .small)
                } else {
                    StatusChip("idle", tone: .neutral, size: .small)
                }
            }

            MacContextRow(label: "Streamed",
                          value: "\(model.streamingText.count) chars",
                          mono: true)
            MacContextRow(label: "Waiting", value: "\(model.pendingRequests.count)")

            if model.isStreaming {
                OpenBotButton("Interrupt", systemImage: "stop.fill", kind: .danger, size: .small) {
                    store.interrupt()
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Context window

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaption("CONTEXT WINDOW")
            // The gateway does not report token usage yet, so there is no gauge to draw.
            // TODO(protocol): render `ContextGauge(used:limit:)` once usage is on the wire.
            Text("Token usage is not reported by this gateway yet.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Skills

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionCaption("SKILLS")
            Text("Skills in play are not on the wire yet — the list arrives with the tools projection.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `LABEL   value` at the inspector's 11/10 pt, with the value on the right.
struct MacContextRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var truncates: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize()

            Spacer(minLength: 4)

            Text(value)
                .font(mono ? Font.system(size: 10, design: .monospaced) : TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(truncates ? .middle : .tail)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private struct ContextPanelPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        ContextPanelView(model: store.model, store: store)
            .frame(height: 640)
            .background(Tokens.sidebar)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Context panel") {
    ContextPanelPreview()
}
