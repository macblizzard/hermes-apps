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
            HStack {
                if searching {
                    TextField("Search messages", text: $query).focused($searchFocused)
                        .accessibilityIdentifier("conversationSearchField")
                    Text(query.isEmpty ? "" : matches.isEmpty ? "No matches" : "\(min(matchIndex + 1, matches.count)) of \(matches.count)")
                        .font(.caption)
                    Button { moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled(matches.isEmpty).accessibilityLabel("Previous search result")
                    Button { moveMatch(1) } label: { Image(systemName: "chevron.down") }
                        .disabled(matches.isEmpty).accessibilityLabel("Next search result")
                    Button("Done") { searching = false; query = ""; matchIndex = 0 }
                } else {
                    Spacer()
                    Button { searching = true; searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                        .keyboardShortcut("f", modifiers: .command)
                        .help("Search conversation")
                }
            }.padding(.horizontal, 24).padding(.top, 8)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .center, spacing: 18) {
                    ForEach(model.transcript) { entry in
                        TranscriptRowView(entry: entry, host: model.hostName, bot: model.selectedBotID ?? "", session: model.selectedSessionID)
                            .id(entry.id)
                            .background(selectedMatch == entry.id ? Color.accentColor.opacity(0.16) : Color.clear)
                            .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
                    }

                    if model.isStreaming {
                        StreamingAssistantBubble(text: model.streamingText)
                            .id(streamingID)
                            .background(selectedMatch == streamingID ? Color.accentColor.opacity(0.16) : Color.clear)
                            .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
                            .transition(.opacity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 24)
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
