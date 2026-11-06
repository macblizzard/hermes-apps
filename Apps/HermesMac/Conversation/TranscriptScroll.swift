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

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
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

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    // Measured, *then* inset: the 640 pt measure is the text column, so the reading
                    // inset sits outside it. Padding the measure instead (what the composer did) left
                    // the field 592 pt wide and every column a different distance from the edge.
                    .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
                    .padding(.horizontal, Geometry.readingInset)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .onChange(of: model.transcript.count) { _, _ in if !searching { scroll(proxy) } }
                .onChange(of: model.streamingText) { _, _ in if !searching { scroll(proxy) } }
                .onChange(of: model.isStreaming) { _, _ in if !searching { scroll(proxy) } }
                .onChange(of: model.selectedSessionID) { _, _ in
                    query = ""; matchIndex = 0
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: query) { _, _ in matchIndex = 0; if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: matchIndex) { _, _ in if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: matches) { _, newMatches in
                    guard searching else { return }
                    matchIndex = min(matchIndex, max(0, newMatches.count - 1))
                    if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .sheet(isPresented: selectionSheetPresented) {
            SelectTextSheet(text: selectionText ?? "") { selectionText = nil }
        }
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

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
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
