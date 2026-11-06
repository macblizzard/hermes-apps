import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The scrolled transcript, with the live turn appended at the bottom.
///
/// Rows are laid out in a `LazyVStack` so a long conversation only builds the rows on
/// screen, and each row is capped at `Geometry.conversationMeasure` (640 pt) — the measure
/// OpenBot draws chat at, which is what keeps a wide window readable.
struct TranscriptScroll: View {
    @ObservedObject var model: AppModel

    @State private var searching = false
    @State private var query = ""
    @State private var matchIndex = 0
    /// "Select Text" is one sheet for the whole transcript, not one per row: a row lives inside a
    /// `LazyVStack`, so a sheet owned by a row is destroyed the moment that row scrolls out.
    @State private var selectionText: String?
    @FocusState private var searchFocused: Bool
    private let streamingID = "conversation-streaming-search"

    private var matches: [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var ids = model.transcript.filter { $0.text.localizedCaseInsensitiveContains(query) }.map(\.id)
        if model.isStreaming && model.streamingText.localizedCaseInsensitiveContains(query) { ids.append(streamingID) }
        return ids
    }

    private var selectedMatch: String? {
        guard searching, matches.indices.contains(matchIndex) else { return nil }
        return matches[matchIndex]
    }

    private func moveMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (min(matchIndex, matches.count - 1) + direction + matches.count) % matches.count
    }

    private let bottomID = "transcript-bottom"

    /// How far the end of the transcript may sit below the fold before the way back down shows.
    /// At the true end the sentinel's bottom *is* the fold (the 10 pt of breathing room is inside
    /// the stack above it), so 20 pt is pure hysteresis: a wheel click or a trackpad nudge must
    /// not summon the control, and it must not flicker while a reply streams in.
    private let revealGap: CGFloat = 20

    /// Where the bottom edge of the *visible* transcript sits, in window coordinates. Measured
    /// rather than taken from a `GeometryReader` height so that both ends of the comparison come
    /// from the same space — on-screen y, whatever the scroll offset — and so a window resize
    /// re-measures it for free.
    @State private var foldEdge: CGFloat = 0

    /// True while new content may pull the transcript down. One measurement feeds both this and
    /// the floating control, so the auto-scroll and the button can never disagree about whether
    /// the newest message is on screen.
    @State private var followsBottom = true

    var body: some View {
        VStack(spacing: 0) {
            // No permanent search *row*: idle, the transcript gets that height back and search is
            // reached with ⌘F (or the palette). The field and its controls exist only while the
            // search is open.
            if searching {
                searchRow
                    .transition(.opacity)
            } else {
                searchShortcut
            }

            transcript
        }
        .sheet(isPresented: selectionSheetPresented) {
            SelectTextSheet(text: selectionText ?? "") { selectionText = nil }
        }
    }

    // MARK: - Transcript

    /// The reader, the scroll view, the two measurements and their handlers.
    ///
    /// Kept out of `body` on purpose: one expression this size is more than the type-checker will
    /// chew in reasonable time ("unable to type-check this expression"), which is the wall the
    /// phone's transcript hit with less on screen.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    rows
                    endSentinel
                }
            }
            // Floating over the transcript's foot — the strip just above the composer, which is
            // where the eye goes looking for it.
            .overlay(alignment: .bottom) { foot(proxy) }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onPreferenceChange(FoldEdgeKey.self) { foldEdge = $0 }
            .onPreferenceChange(BottomEdgeKey.self) { syncFollowState(edgeBottom: $0) }
            .onChange(of: model.transcript.count) { _, _ in follow(proxy) }
            .onChange(of: model.streamingText) { _, _ in follow(proxy) }
            .onChange(of: model.isStreaming) { _, _ in follow(proxy) }
            .onChange(of: model.selectedSessionID) { _, _ in openSession(proxy) }
            .onChange(of: query) { _, _ in
                matchIndex = 0
                if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: matchIndex) { _, _ in
                if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: matches) { _, newMatches in
                guard searching else { return }
                matchIndex = min(matchIndex, max(0, newMatches.count - 1))
                if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The messages, on the reading measure.
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(model.transcript) { entry in
                TranscriptRowView(entry: entry,
                                  host: model.hostName,
                                  bot: model.selectedBotID ?? "",
                                  session: model.selectedSessionID,
                                  onSelectText: { selectionText = $0 })
                    .id(entry.id)
                    .background(selectedMatch == entry.id ? Color.accentColor.opacity(0.16) : Color.clear)
            }

            if model.isStreaming {
                StreamingAssistantBubble(text: model.streamingText)
                    .id(streamingID)
                    .background(selectedMatch == streamingID ? Color.accentColor.opacity(0.16) : Color.clear)
                    .transition(.opacity)
            }
        }
        // Measured, *then* inset: the 640 pt measure is the text column, so the reading inset
        // sits outside it. Padding the measure instead (what the composer did) left the field
        // 592 pt wide and every column a different distance from the edge.
        .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
        .padding(.horizontal, Geometry.readingInset)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    /// The end of the transcript as a marker of its own, not as the lazy stack's last row: a row
    /// is only built once it comes into view, and a sentinel a screenful away would report
    /// nothing until the user was already there.
    private var endSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(bottomID)
            .background(
                GeometryReader { edge in
                    Color.clear.preference(key: BottomEdgeKey.self,
                                           value: edge.frame(in: .global).maxY)
                }
            )
    }

    /// The foot of the viewport: the fold the threshold is measured against, and the control that
    /// returns to the newest message. Both ride in one stack, so the two measurements come out of
    /// the same space and the comparison is a plain subtraction.
    private func foot(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: 1)
                .allowsHitTesting(false)
                .background(
                    GeometryReader { fold in
                        Color.clear.preference(key: FoldEdgeKey.self,
                                               value: fold.frame(in: .global).maxY)
                    }
                )

            Group {
                // Hidden while the search row is up: the search owns the scroll position then,
                // and this would compete with the chevrons that step through matches.
                if !searching, !followsBottom {
                    scrollToBottomButton(proxy)
                }
            }
            .animation(.easeOut(duration: 0.18), value: followsBottom)
        }
    }

    // MARK: - Following the newest message

    /// Pull the transcript down only while it is already at the bottom.
    ///
    /// A user who scrolled up keeps their place: a streaming reply must not yank the reading
    /// position back on every token, which is what the old unconditional scroll did. The
    /// floating control is the way back, and taking it re-arms the follow.
    private func follow(_ proxy: ScrollViewProxy) {
        guard !searching, followsBottom else { return }
        scroll(proxy)
    }

    /// A different conversation opens at its newest message, whatever the previous one's reading
    /// position was — the follow is re-armed with it.
    private func openSession(_ proxy: ScrollViewProxy) {
        query = ""
        matchIndex = 0
        followsBottom = true
        proxy.scrollTo(bottomID, anchor: .bottom)
    }

    /// The one place `followsBottom` changes — and it writes only when the verdict flips.
    ///
    /// Pinned to the bottom, the sentinel does not move relative to the fold, so streaming raises
    /// no event at all. Scrolled up, it moves with every token; this guard keeps those events from
    /// re-rendering the transcript on each one.
    ///
    /// The comparison is sentinel-against-fold, both in window coordinates: the verdict is a
    /// plain on-screen fact, untouched by how SwiftUI resolves scroll offsets internally.
    private func syncFollowState(edgeBottom: CGFloat) {
        guard foldEdge > 0 else { return }
        let shouldFollow = edgeBottom - foldEdge <= revealGap
        if shouldFollow != followsBottom { followsBottom = shouldFollow }
    }

    /// The way back down: a circle centred on the column, floating just above the composer, with
    /// the same quiet surface as the composer's own controls. Drawn only when the measurement
    /// says a message is out of sight.
    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            // No `followsBottom = true` here: the sentinel is still below the fold while the
            // scroll animates, and claiming otherwise would flip the verdict back and make the
            // button blink out and in on the way down. Landing sets it.
            scroll(proxy, duration: 0.28)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.textMuted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Tokens.control))
                .overlay(Circle().strokeBorder(Tokens.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Scroll to latest message")
        .accessibilityLabel("Scroll to latest message")
        .accessibilityIdentifier("conversationScrollToBottom")
        .padding(.bottom, 14)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    // MARK: - Search

    /// The open search: field, match count, the two chevrons and Done, on the same measure and
    /// reading inset as the transcript beneath it.
    private var searchRow: some View {
        HStack(spacing: 6) {
            TextField("Search messages", text: $query)
                .focused($searchFocused)
                .accessibilityIdentifier("conversationSearchField")

            Text(countLabel)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(isEmptySearch ? Tokens.warning : Tokens.textMuted)
                .lineLimit(1)
                .accessibilityIdentifier("conversationSearchCount")

            OpenBotIconButton("chevron.up",
                              label: "Previous search result",
                              size: .small,
                              isDisabled: matches.isEmpty) {
                moveMatch(-1)
            }
            OpenBotIconButton("chevron.down",
                              label: "Next search result",
                              size: .small,
                              isDisabled: matches.isEmpty) {
                moveMatch(1)
            }

            TextButton("Done", tone: Tokens.textMuted) { closeSearch() }
        }
        .padding(.horizontal, Geometry.readingInset)
        .padding(.top, 8)
        .frame(maxWidth: Geometry.conversationMeasure + Geometry.readingInset * 2)
        .frame(maxWidth: .infinity)
    }

    /// The keyboard door to search, kept while the row is hidden so ⌘F still works — and kept as a
    /// real `Button` with the same accessibility identifier, so the shortcut is discoverable to
    /// VoiceOver and to the UI tests.
    private var searchShortcut: some View {
        Button {
            searching = true
            searchFocused = true
        } label: {
            EmptyView()
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityIdentifier("conversationSearchToggle")
        .accessibilityLabel("Search conversation")
        .help("Search conversation (⌘F)")
    }

    private var countLabel: String {
        guard !query.isEmpty else { return "" }
        return matches.isEmpty ? "No matches" : "\(min(matchIndex + 1, matches.count)) of \(matches.count)"
    }

    private var isEmptySearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && matches.isEmpty
    }

    private var selectionSheetPresented: Binding<Bool> {
        Binding(get: { selectionText != nil },
                set: { if !$0 { selectionText = nil } })
    }

    private func closeSearch() {
        searching = false
        query = ""
        matchIndex = 0
    }

    private func scroll(_ proxy: ScrollViewProxy, duration: Double = 0.15) {
        withAnimation(.easeOut(duration: duration)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

/// Where the end of the transcript currently sits, in window coordinates.
/// One writer, so the last value wins; the reader thresholds it and ignores everything else.
private struct BottomEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The bottom edge of the visible transcript, in window coordinates — the line the floating
/// control sits on. Constant except when the window or the pane changes size; the pair is what
/// turns "is the end below the fold" into a subtraction.
private struct FoldEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The assistant's turn while it is still arriving.
///
/// The first token can take a while, so an empty stream shows the spinner instead of an
/// empty bubble — but the moment there is text it is rendered through the same
/// `MarkdownTextView` a finished message uses, so nothing jumps when the turn completes.
struct StreamingAssistantBubble: View {
    let text: String

    var body: some View {
        Group {
            if text.isEmpty {
                HStack(spacing: 8) {
                    SpinningRing(color: Tokens.accent, size: 11, lineWidth: 1.5)
                    Text("Hermes is working…")
                        .font(TypeScale.font(Tokens.textMD))
                        .foregroundStyle(Tokens.textMuted)
                }
                .padding(.vertical, 2)
                .accessibilityLabel("Hermes is working")
            } else {
                MarkdownTextView(text: text, isStreaming: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One message, whole, in a sheet of its own. Owned by `TranscriptScroll` rather than by the row
/// that opened it, so scrolling the row out of view while reading cannot take the sheet with it.
struct SelectTextSheet: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Select Text")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
                TextButton("Done", tone: Tokens.textMuted, action: onDone)
            }

            ScrollView {
                Text(text)
                    .font(TypeScale.font(TypeScale.chatBody))
                    .lineSpacing(TypeScale.chatLineSpacing)
                    .foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 240)
        .background(Tokens.sheet)
    }
}

// MARK: - Previews

private struct TranscriptScrollPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.streaming)

    var body: some View {
        TranscriptScroll(model: store.model)
            .frame(width: Geometry.conversationMeasure + 160, height: 620)
            .background(Tokens.canvas)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct StreamingBubblePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StreamingAssistantBubble(text: "")
            StreamingAssistantBubble(text: "Snapshotting the vault first, then I'll diff the `docs/` tree.")
        }
        .padding(24)
        .frame(width: Geometry.conversationMeasure, alignment: .leading)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#Preview("Transcript · streaming") {
    TranscriptScrollPreview()
}

#Preview("Streaming bubble") {
    StreamingBubblePreview()
}
