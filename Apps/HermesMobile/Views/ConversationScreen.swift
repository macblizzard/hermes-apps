import SwiftUI
import UIKit
import UniformTypeIdentifiers
import HermesKit
import HermesAppKit
import OpenBotUI

/// The conversation with one bot — one endless thread, always.
///
/// There is no session browser here and none anywhere else: opening a bot asks the model
/// for that bot's stored (or freshly created) session and attaches to it. The header is
/// the bot, the model the host named, the wire latency and how full the context window is;
/// compaction sits behind the overflow menu. The thread is never reset or retitled
/// automatically, so its history stays reachable.
struct ConversationScreen: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment

    let bot: Bot

    @State private var sessionID: SessionID?
    @State private var isOpening = true
    @State private var showApprovalSheet = false
    @State private var notice: String?
    @State private var lastSeenRequestCount = 0
    @State private var hasLoaded = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardScreenSize: CGSize = .zero
    @State private var keyboardScrollTask: Task<Void, Never>?
    @State private var isDraggingTranscript = false
    @State private var showAttachmentMenu = false
    @State private var attachmentSource: AttachmentSource?

    /// One voice controller per conversation screen: recording, transcription and
    /// playback share an audio session, so they must not race each other.
    @StateObject private var voice = VoiceController()
    /// Opt-in and never persisted: speaking replies is a per-visit choice.
    @State private var speakReplies = false
    @State private var lastSpokenEntryID: String?
    @State private var showBotSettings = false
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchIndex = 0
    @FocusState private var searchFocused: Bool

    private static let bottomID = "conversation-bottom"
    private static let streamingSearchID = "conversation-streaming-search"

    private func accept(_ result: Result<AttachmentPayload, Error>) {
        attachmentSource = nil
        switch result {
        case .success(let payload):
            model.addPendingAttachment(name: payload.name, data: payload.data, isImage: payload.isImage)
        case .failure(let error):
            notice = error.localizedDescription
        }
    }

    /// The menu closes before the picker opens: they are separate presentations and the
    /// overlay must not sit on top of a system sheet.
    private func pick(_ source: AttachmentSource) {
        closeAttachmentMenu()
        switch source {
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                notice = AttachmentPickerError.cameraUnavailable.localizedDescription
                return
            }
            attachmentSource = .camera
        case .photos:
            attachmentSource = .photos
        case .files:
            attachmentSource = .files
        }
    }

    private func closeAttachmentMenu() {
        showAttachmentMenu = false
    }

    private var title: String { bot.displayName }

    var body: some View {
        transcriptScroll
        // Tapping the thread closes the paperclip's menu, the way any transient menu behaves.
        .overlay {
            if showAttachmentMenu {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { closeAttachmentMenu() }
                    .accessibilityHidden(true)
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
        .safeAreaInset(edge: .top, spacing: 0) { headerStrip }
        .onAppear { model.setVisibleBot(bot.id) }
        .onDisappear { model.setVisibleBot(nil) }
        .task(id: bot.id) {
            voice.transport = app.makeVoiceTransport()
            await openConversation()
        }
        .onChange(of: app.store.host) { _, _ in
            // A re-pair or host switch changes the endpoint the controller may talk to.
            voice.cancel()
            voice.transport = app.makeVoiceTransport()
        }
        .onChange(of: model.transcript.count) { _, _ in
            speakNewReplyIfNeeded()
        }
        .onChange(of: model.pendingRequests.count) { count in
            let arrived = hasLoaded && count > lastSeenRequestCount
            lastSeenRequestCount = count
            guard arrived, model.pendingRequests.first != nil else { return }
            Haptics.approvalArrived()
            showApprovalSheet = true
        }
        .sheet(isPresented: $showBotSettings) {
            BotModelSettingsScreen(
                bot: bot,
                load: { botID in try await model.modelCatalog(for: botID) },
                conversationIsOpen: true,
                save: { botID, option, confirmed in
                    switch try await model.configureModel(botID: botID, model: option.id,
                                                          provider: option.provider,
                                                          confirm: confirmed) {
                    case .applied: return .saved
                    case .confirmationRequired(let message): return .confirmationRequired(message)
                    }
                },
                // Memberwise order matters: `save` precedes `saveDescription` in the declaration.
                saveDescription: { botID, text in
                    try await model.configureDescription(botID: botID, description: text)
                })
        }
        // The choices live in the composer, anchored to the paperclip (`AttachmentMenu`); this
        // is only the system picker for the one the user chose.
        .sheet(item: $attachmentSource) { source in
            switch source {
            case .camera:
                AttachmentCamera(completion: { accept($0) },
                                 cancel: { attachmentSource = nil }).ignoresSafeArea()
            case .photos:
                AttachmentPhotos(completion: { accept($0) },
                                 cancel: { attachmentSource = nil }).ignoresSafeArea()
            case .files:
                AttachmentFiles(completion: { accept($0) },
                                cancel: { attachmentSource = nil })
            }
        }
        .sheet(isPresented: $showApprovalSheet) {
            MobileApprovalSheet(model: model, request: model.pendingRequests.first)
        }
        .alert("Couldn’t add attachment", isPresented: noticeBinding) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Header

    /// The header's second line, directly under the bot name: what is answering, over what
    /// wire, and how much of the window the thread has used. All three are facts the host
    /// reported — a missing fact is omitted, never guessed.
    private var headerStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let label = modelChipLabel {
                    StatusChip(label, tone: .neutral, size: .small)
                }

                if let usage = contextUsage {
                    Text(usage)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(contextTint)
                        .lineLimit(1)
                        .accessibilityLabel("Context used, \(usage) tokens")
                }

                Spacer(minLength: 6)

                MobileConnectionPill(connection: model.connection, rttMS: app.effectiveRTT)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minHeight: 30)

            Hairline(color: Tokens.border)
            if isSearching {
                searchBar
                Hairline(color: Tokens.border)
            }
        }
        .background(Tokens.canvas)
    }

    /// `deepseek-v4.1-flash` fits; a provider-qualified id does not, and the chip is
    /// `fixedSize`, so it is shortened here rather than pushing the latency chip off.
    private var modelChipLabel: String? {
        guard let raw = model.modelLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let words = raw.split(separator: " ")
        let short = words.prefix(2).joined(separator: " ")
        guard !short.isEmpty else { return nil }
        return short.count <= 22 ? short : String(short.prefix(21)) + "…"
    }

    /// `12k / 1M` — only when the host has reported both halves of the window.
    private var contextUsage: String? {
        guard let used = model.contextUsed, let limit = model.contextMax else { return nil }
        return "\(MobileTokens.short(used)) / \(MobileTokens.short(limit))"
    }

    private var contextTint: Color {
        guard let fraction = model.contextFraction else { return Tokens.textDim }
        if fraction >= 0.85 { return Tokens.danger }
        if fraction >= 0.70 { return Tokens.warning }
        return Tokens.textDim
    }

    // MARK: Transcript

    /// Search visible transcript text, including the summaries of tool and reasoning rows.
    private var searchMatches: [String] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var ids = model.transcript.filter { entry in
            entry.text.localizedCaseInsensitiveContains(searchText)
        }.map(\.id)
        if !model.streamingText.isEmpty,
           model.streamingText.localizedCaseInsensitiveContains(searchText) {
            ids.append(Self.streamingSearchID)
        }
        return ids
    }

    private var selectedSearchID: String? {
        let matches = searchMatches
        guard isSearching, matches.indices.contains(searchIndex) else { return nil }
        return matches[searchIndex]
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.textMuted)
            TextField("Search messages", text: $searchText)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("conversationSearchField")
            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "" : searchMatches.isEmpty ? "No matches" : "\(min(searchIndex + 1, searchMatches.count)) of \(searchMatches.count)")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize()
                .accessibilityIdentifier("conversationSearchCount")
            Button { moveSearch(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(searchMatches.isEmpty)
                .accessibilityLabel("Previous search result")
            Button { moveSearch(1) } label: { Image(systemName: "chevron.down") }
                .disabled(searchMatches.isEmpty)
                .accessibilityLabel("Next search result")
            Button("Done") {
                searchFocused = false
                isSearching = false
                searchText = ""
                searchIndex = 0
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { searchFocused = true }
    }

    private func moveSearch(_ direction: Int) {
        let count = searchMatches.count
        guard count > 0 else { return }
        searchIndex = (min(searchIndex, count - 1) + direction + count) % count
    }

    private func scrollToSearchResult(_ proxy: ScrollViewProxy) {
        guard let id = selectedSearchID else { return }
        withAnimation(Motion.messageIn) { proxy.scrollTo(id, anchor: .center) }
    }

    /// Split out of `body` on purpose: a ScrollViewReader + ScrollView + LazyVStack + six
    /// conditionals in one expression exceeded the type-checker's budget
    /// ("unable to type-check this expression in reasonable time").
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptList
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { _ in
                    isDraggingTranscript = true
                    keyboardScrollTask?.cancel()
                }
                .onEnded { _ in isDraggingTranscript = false })
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                keyboardFrameChanged(notification, proxy: proxy)
            }
            .onDisappear {
                keyboardScrollTask?.cancel()
                keyboardHeight = 0
                isDraggingTranscript = false
            }
            .onChange(of: model.transcript.count) {
                scroll(proxy, animated: true)
            }
            .onChange(of: model.streamingText) {
                scroll(proxy, animated: false)
            }
            .onChange(of: model.liveTools.count) {
                scroll(proxy, animated: false)
            }
            .onChange(of: model.reasoningText) {
                scroll(proxy, animated: false)
            }
            .onChange(of: searchText) {
                searchIndex = 0
                scrollToSearchResult(proxy)
            }
            .onChange(of: searchIndex) {
                scrollToSearchResult(proxy)
            }
            .onChange(of: searchMatches) {
                guard isSearching else { return }
                searchIndex = min(searchIndex, max(0, searchMatches.count - 1))
                scrollToSearchResult(proxy)
            }
        }
    }

    private var transcriptList: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if isBlank {
                if isOpening {
                    openingState
                } else {
                    MobileTranscriptEmpty(title: title)
                }
            }

            ForEach(model.transcript) { entry in
                MobileTranscriptRow(entry: entry)
                    .overlay {
                        if selectedSearchID == entry.id {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Tokens.accentText, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .id(entry.id)
            }

            if !model.pendingRequests.isEmpty {
                pendingSection
            }

            if let notice = model.compactionNotice {
                // Auto-compaction rewrites the stored transcript; without a line the conversation
                // would just get shorter with no explanation.
                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                    .accessibilityIdentifier("compactionNotice")
            }

            if model.showReasoning, !model.reasoningText.isEmpty {
                MobileReasoningBlock(text: model.reasoningText)
            }

            if !model.liveTools.isEmpty {
                liveToolsSection
            }

            if model.isStreaming || !model.streamingText.isEmpty {
                MobileStreamingBubble(text: model.streamingText)
                    .overlay {
                        if selectedSearchID == Self.streamingSearchID {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Tokens.accentText, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .id(Self.streamingSearchID)
            }

            Color.clear
                .frame(height: 1)
                .id(ConversationScreen.bottomID)
        }
    }

    private var isBlank: Bool {
        model.transcript.isEmpty
            && !model.isStreaming
            && model.pendingRequests.isEmpty
            && model.liveTools.isEmpty
            && model.reasoningText.isEmpty
    }

    private var openingState: some View {
        HStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 12, lineWidth: 1.5)
            Text("Opening \(title)…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Live tool calls for the turn in flight.
    ///
    /// `input`/`output` are copied out as `String?` first: the card takes optional text, and
    /// the model is free to hand back either shape. The output is only passed when the user
    /// asked to see tool output in Settings *and* the tool actually produced some — an empty
    /// result is not a result.
    private var liveToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.liveTools) { tool in
                let input: String? = tool.input
                let output: String? = tool.output
                MobileToolRow(name: tool.name,
                              summary: toolSummary(input),
                              output: model.showToolOutput ? output : nil,
                              isRunning: tool.isRunning,
                              durationMS: tool.durationMS)
            }
        }
    }

    /// The first line of a tool's arguments, short enough for a card header.
    private func toolSummary(_ input: String?) -> String? {
        guard let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let firstLine = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? input
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(90))
    }

    // MARK: Header controls

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
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

                Menu {
                    Button {
                        isSearching = true
                        searchFocused = true
                    } label: {
                        Label("Search conversation", systemImage: "magnifyingglass")
                    }

                    Button {
                        showBotSettings = true
                    } label: {
                        Label("Bot settings", systemImage: "gearshape")
                    }

                    Button {
                        Task { await model.compressNow() }
                    } label: {
                        Label("Compact now", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(sessionID == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Tokens.textSecondary)
                }
                .accessibilityLabel("Conversation actions")
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

            if !model.pendingAttachments.isEmpty {
                pendingAttachmentsBar
            }

            voiceRow

            Hairline(color: Tokens.border)

            Composer(text: $model.draft,
                     placeholder: "Message \(title)",
                     isSending: model.isBusy,
                     isDisabled: sessionID == nil,
                     hasAttachments: !model.pendingAttachments.isEmpty,
                     onSend: { Task { await model.send() } },
                     onAttach: {
                         withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                             showAttachmentMenu.toggle()
                         }
                     },
                     onMic: { toggleRecording() },
                     onInterrupt: { Task { await model.interrupt() } })
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                // Anchored to the paperclip, above it: the card is an overlay, not a
                // presentation, so nothing here can be dismissed out from under it.
                .overlay(alignment: .topLeading) {
                    if showAttachmentMenu {
                        AttachmentMenu(onPick: pick)
                            .padding(.leading, 4)
                            .offset(y: -(AttachmentMenu.height + 10))
                            .transition(.scale(scale: 0.9, anchor: .bottomLeading)
                                .combined(with: .opacity))
                    }
                }
        }
        .background(Tokens.canvas)
    }

    /// The microphone and the "speak replies" opt-in, on one quiet line above the field.
    ///
    /// A transcript fills the draft and never sends on its own: misrecognition is common
    /// enough that the user should see the words before they leave the phone. Speaking is
    /// opt-in per visit and only starts for replies that arrive while it is on.
    private var voiceRow: some View {
        HStack(spacing: 8) {
            VoiceRecordButton(controller: voice,
                              isEnabled: sessionID != nil,
                              onTranscript: insertTranscript)
            VoiceSpeakerToggle(controller: voice,
                               isEnabled: Binding(get: { speakReplies },
                                                  set: { enabled in
                                                      speakReplies = enabled
                                                      // History is not replayed: mark what exists now.
                                                      if enabled {
                                                          lastSpokenEntryID = lastAssistantReply?.id
                                                      }
                                                  }),
                               hasReply: lastAssistantReply != nil)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    /// Picked attachments wait here until the user sends, so cancelling the composer uploads nothing.
    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage {
                            AttachmentThumbnail(data: attachment.data, size: 26)
                        } else {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                        }
                        Text(attachment.name)
                            .font(TypeScale.font(TypeScale.sm))
                            .lineLimit(1)
                        Button {
                            model.removePendingAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Tokens.surface, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
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

    // MARK: Endless session

    /// One thread per bot: resume the stored session, or let the model create and store a
    /// new one, then attach to it. The id comes from the model, never from a session list —
    /// and the model does the attaching (bot switch, resume, transcript) in one place, so
    /// there is no second resume here.
    private func openConversation() async {
        isOpening = true

        if let sid = await model.endlessSession(for: bot.id) {
            sessionID = sid
        } else {
            sessionID = nil
        }

        // Requests that were already open when this session was resumed belong in the
        // transcript, not in a sheet the user never asked for; only *arrivals* pop one.
        lastSeenRequestCount = model.pendingRequests.count
        hasLoaded = true
        isOpening = false
    }

    // MARK: Helpers

    private var noticeBinding: Binding<Bool> {
        Binding(get: { notice != nil },
                set: { presented in
                    if !presented { notice = nil }
                })
    }

    // MARK: Voice

    /// The reply the speaker toggle would repeat: the newest assistant row on screen.
    private var lastAssistantReply: TranscriptEntry? {
        model.transcript.last { $0.role == .assistant && !$0.text.isEmpty }
    }

    private func toggleRecording() {
        // Refresh first: the pairing may have changed since this screen appeared.
        voice.transport = app.makeVoiceTransport()
        if voice.state == .recording {
            voice.stopAndTranscribe(onTranscript: insertTranscript)
        } else {
            voice.startRecording()
        }
    }

    /// Put the transcript where the user can read it before it is sent: replace an empty
    /// draft, otherwise append as a new sentence. Sending stays a deliberate tap.
    private func insertTranscript(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let existing = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.draft = existing.isEmpty ? spoken : existing + " " + spoken
    }

    /// Speak a reply only when it is new and the toggle was already on. The same row is
    /// never spoken twice, and toggling on marks the current reply as seen.
    private func speakNewReplyIfNeeded() {
        guard speakReplies, voice.state == .idle else { return }
        guard let reply = lastAssistantReply,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard reply.id != lastSpokenEntryID else { return }
        lastSpokenEntryID = reply.id
        voice.transport = app.makeVoiceTransport()
        voice.speak(reply.text)
    }

    /// Scroll after the keyboard's safe-area animation has settled, not when focus first
    /// changes (at that point the scroll view still has its old height). Frame changes also
    /// cover keyboard size changes and rotation; dismissal never pulls history to the bottom.
    private func keyboardFrameChanged(_ notification: Notification, proxy: ScrollViewProxy) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screen = UIScreen.main.bounds
        let intersection = screen.intersection(frame)
        let height = !intersection.isNull && frame.maxY >= screen.maxY - 1
            ? intersection.height : 0
        let previousHeight = keyboardHeight
        let sizeChanged = keyboardScreenSize != .zero && keyboardScreenSize != screen.size
        keyboardScreenSize = screen.size
        guard abs(height - previousHeight) > 1 || sizeChanged else { return }
        keyboardHeight = height
        keyboardScrollTask?.cancel()
        // A shrinking keyboard reveals more history; do not fight interactive dismissal.
        guard !isSearching, height > 0, !isDraggingTranscript,
              height > previousHeight || sizeChanged else { return }

        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        keyboardScrollTask = Task { @MainActor in
            // Allow the keyboard animation and the following SwiftUI layout pass to finish.
            let delay = max(0, min(duration, 2)) + 0.05
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, !isDraggingTranscript else { return }
            scroll(proxy, animated: false)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !isSearching, (!model.transcript.isEmpty || model.isStreaming) else { return }
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
        ConversationScreen(model: environment.model, bot: Bot(id: "cody", displayName: "Cody"))
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Conversation · streaming") {
    let environment = AppEnvironment.preview(scenario: .streaming)
    NavigationStack {
        ConversationScreen(model: environment.model, bot: Bot(id: "cody", displayName: "Cody"))
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}

#Preview("Conversation · approval arrives") {
    let environment = AppEnvironment.preview(scenario: .approval)
    NavigationStack {
        ConversationScreen(model: environment.model, bot: Bot(id: "cody", displayName: "Cody"))
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
