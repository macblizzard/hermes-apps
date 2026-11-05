import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// The conversation.
///
/// Native chrome does the work: a compact principal toolbar item is the header, the
/// composer is a bottom safe-area inset (so the keyboard pushes it rather than covering
/// it), and the reconnect strip is a top inset. Everything else is the transcript.
struct ConversationScreen: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment

    let sessionID: SessionID

    @State private var showApprovalSheet = false
    @State private var notice: String?
    @State private var lastSeenRequestCount = 0
    @State private var hasLoaded = false

    private static let bottomID = "conversation-bottom"

    private var title: String { app.title(for: sessionID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.transcript.isEmpty && !model.isStreaming && model.pendingRequests.isEmpty {
                        MobileTranscriptEmpty(title: title)
                    }

                    ForEach(model.transcript) { entry in
                        MobileTranscriptRow(entry: entry)
                            .id(entry.id)
                    }

                    if !model.pendingRequests.isEmpty {
                        pendingSection
                    }

                    if model.isStreaming || !model.streamingText.isEmpty {
                        MobileStreamingBubble(text: model.streamingText)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(ConversationScreen.bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.transcript.count) { _ in
                scroll(proxy, animated: true)
            }
            .onChange(of: model.streamingText) { _ in
                scroll(proxy, animated: false)
            }
        }
        .background(Tokens.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { composerArea }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: sessionID) {
            await model.select(sessionID)
            // Requests that were already open when this session was resumed belong in the
            // transcript, not in a sheet the user never asked for; only *arrivals* pop one.
            lastSeenRequestCount = model.pendingRequests.count
            hasLoaded = true
        }
        .onChange(of: model.pendingRequests.count) { count in
            let arrived = hasLoaded && count > lastSeenRequestCount
            lastSeenRequestCount = count
            guard arrived, model.pendingRequests.first != nil else { return }
            Haptics.approvalArrived()
            showApprovalSheet = true
        }
        .sheet(isPresented: $showApprovalSheet) {
            MobileApprovalSheet(model: model, request: model.pendingRequests.first)
        }
        .alert("Not yet", isPresented: noticeBinding) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 3) {
                Text(title)
                    .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let label = app.modelChipLabel {
                        StatusChip(label, tone: .neutral, size: .small)
                    }
                    MobileConnectionPill(connection: model.connection, rttMS: app.effectiveRTT)
                }
            }
            .accessibilityElement(children: .combine)
        }

        ToolbarItem(placement: .topBarTrailing) {
            if model.isStreaming {
                Button {
                    Haptics.impact()
                    Task { await model.interrupt() }
                } label: {
                    Image(systemName: "stop.circle")
                        .foregroundStyle(Tokens.danger)
                }
                .accessibilityLabel("Interrupt the turn")
            }
        }
    }

    // MARK: Pending requests

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = model.pendingRequests.first {
                MobilePendingRequestCard(model: model,
                                         request: request,
                                         onExpand: { showApprovalSheet = true })
            }

            if model.pendingRequests.count > 1 {
                Text("\(model.pendingRequests.count - 1) more waiting behind this one")
                    .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                    .foregroundStyle(Tokens.warning)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: Composer

    private var composerArea: some View {
        VStack(spacing: 0) {
            if let error = model.lastSendError {
                sendErrorBar(error)
            }

            Hairline(color: Tokens.border)

            Composer(text: $model.draft,
                     placeholder: "Message Hermes",
                     isSending: model.isBusy,
                     onSend: { Task { await model.send() } },
                     onAttach: { notice = "Attachments arrive with the file-handling milestone." },
                     onMic: { notice = "Dictation arrives with the voice milestone." },
                     onInterrupt: { Task { await model.interrupt() } })
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .background(Tokens.canvas)
    }

    private func sendErrorBar(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.danger)

            Text(error)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            TextButton("Retry", tone: Tokens.accentText) {
                Task { await model.send() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.dangerSoft)
    }

    // MARK: Helpers

    private var noticeBinding: Binding<Bool> {
        Binding(get: { notice != nil },
                set: { presented in
                    if !presented { notice = nil }
                })
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !model.transcript.isEmpty || model.isStreaming else { return }
        if animated {
            withAnimation(Motion.messageIn) {
                proxy.scrollTo(ConversationScreen.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(ConversationScreen.bottomID, anchor: .bottom)
        }
    }
}

// MARK: - Previews

#Preview("Conversation") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        ConversationScreen(model: environment.model, sessionID: "preview-1")
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Conversation · streaming") {
    let environment = AppEnvironment.preview(scenario: .streaming)
    NavigationStack {
        ConversationScreen(model: environment.model, sessionID: "preview-1")
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Conversation · approval arrives") {
    let environment = AppEnvironment.preview(scenario: .approval)
    NavigationStack {
        ConversationScreen(model: environment.model, sessionID: "preview-1")
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
