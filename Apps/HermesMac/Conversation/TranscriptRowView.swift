import AppKit
import HermesKit
import HermesRender
import OpenBotUI
import SwiftUI

/// One transcript entry, drawn by role.
///
/// The roles are deliberately *not* the same shape: a user turn is a right-aligned bubble
/// you wrote, an assistant turn is a document you read, a tool line is a card, and a system
/// line is punctuation. Colour alone never carries the difference — the alignment and the
/// surface do.
struct TranscriptRowView: View {
    let entry: TranscriptEntry
    var host: String = ""
    var bot: String = ""
    var session: String? = nil
    /// "Select Text" is presented by `TranscriptScroll`: a row inside a `LazyVStack` is torn down
    /// when it scrolls out, and a sheet it owns goes with it. The row asks; the transcript shows.
    var onSelectText: (String) -> Void = { _ in }
    @State private var showingReactions = false
    @AppStorage("mac.messageReactions.v1") private var storedReactions = "{}"
    private static let emojis = ["👍", "❤️", "😂", "😮", "😢", "🎉"]
    /// The window's one voice. `@ObservedObject` so the row repaints the moment another message
    /// takes the speaker away from it.
    @ObservedObject private var speech = SpeechReader.shared
    @State private var isHovered = false

    private var reactionKey: String? {
        guard let session else { return nil }
        let message = entry.rowID.map { "row:\($0)" } ?? "live:\(entry.id)"
        return [host, bot, session, message].map { "\($0.utf8.count):\($0)" }.joined()
    }

    private var reactions: [String: String] {
        guard let data = storedReactions.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    private func toggleReaction(_ emoji: String) {
        guard let key = reactionKey else { return }
        var values = reactions
        values[key] = values[key] == emoji ? nil : emoji
        if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
            storedReactions = text
        }
    }

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 4) {
            content.contextMenu { messageMenu }
            if let key = reactionKey, let emoji = reactions[key] {
                Button(emoji) { toggleReaction(emoji) }
                    .accessibilityLabel("Remove local reaction \(emoji)")
            }
        }
        .popover(isPresented: $showingReactions) {
            VStack {
                Text("Reactions are local to this Mac").font(.caption)
                HStack {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button(emoji) { toggleReaction(emoji); showingReactions = false }
                            .buttonStyle(.plain)
                            .font(.title2)
                            .accessibilityLabel("React with \(emoji)")
                    }
                }
            }.padding()
        }
    }

    @ViewBuilder private var messageMenu: some View {
        if entry.role == .user || entry.role == .assistant {
            Button("Select Text") { onSelectText(entry.text) }
            Button(isSpeaking ? "Stop Reading" : "Read Aloud") {
                speech.toggle(id: entry.id, text: entry.text)
            }
            if reactionKey != nil { Button("Add Local Reaction…") { showingReactions = true } }
        }
        ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }
        Button("Copy Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
    }

    @ViewBuilder private var content: some View {
        switch entry.role {
        case .user:
            userRow
        case .assistant:
            assistantRow
        case .tool:
            toolRow
        case .reasoning:
            reasoningRow
        case .system:
            systemRow
        }
    }

    // MARK: User

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Geometry.conversationMeasure * 0.18)

            Text(entry.text)
                .font(TypeScale.font(Tokens.chatBodyMacOS))
                // The same leading the assistant's prose gets: one table for chat text.
                .lineSpacing(TypeScale.chatLineSpacing)
                .foregroundStyle(Tokens.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .accessibilityLabel("You said: \(entry.text)")
        }
    }

    // MARK: Assistant

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownTextView(text: entry.text)
                .accessibilityLabel("Hermes said: \(entry.text)")

            // Read aloud belongs on the message, not only in a context menu nobody right-clicks
            // a reply to find. Quiet until hovered, so the prose still leads.
            readAloudControl
                .opacity(isHovered || isSpeaking ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    // MARK: Read aloud

    private var isSpeaking: Bool { speech.speakingEntryID == entry.id }

    private var readAloudControl: some View {
        Button {
            speech.toggle(id: entry.id, text: entry.text)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2")
                    .font(.system(size: 9, weight: .semibold))
                Text(isSpeaking ? "Stop" : "Read aloud")
                    .font(TypeScale.font(TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(isSpeaking ? Tokens.accentText : Tokens.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                    .fill(isSpeaking ? Tokens.controlActive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSpeaking ? "Stop reading this message" : "Read this message aloud")
        .accessibilityLabel(isSpeaking ? "Stop reading this message" : "Read this message aloud")
        .accessibilityIdentifier("message.readAloud")
    }

    // MARK: Tool

    private var toolRow: some View {
        ToolCard(name: toolProjection.name,
                 summary: toolProjection.summary,
                 status: .done,
                 output: toolProjection.output,
                 startsExpanded: false)
    }

    /// A history tool row from the host's projection carries its own `name`, `context` and `args`
    /// (plus `content` for the editing tools), so the card is built from those. The flat-string
    /// split below only covers old rows that predate the projection — those rendered as a card
    /// labelled "tool" with nothing expandable in it.
    private var toolProjection: (name: String, summary: String?, output: String?) {
        if let tool = entry.tool {
            let name = tool.name.isEmpty ? "tool" : tool.name
            return (name, tool.context ?? legacyProjection.summary, tool.detail)
        }
        return legacyProjection
    }

    private var legacyProjection: (name: String, summary: String?, output: String?) {
        let parts = entry.text
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let name = parts.first else { return ("tool", nil, nil) }
        let rest = parts.dropFirst()
        return (name, rest.isEmpty ? nil : rest.joined(separator: " · "), nil)
    }

    // MARK: Reasoning

    /// The model's reasoning for a finished turn, kept in the thread.
    ///
    /// Recessed and quiet: it explains the answer rather than competing with it, which is why it
    /// is dim text and not a bubble.
    private var reasoningRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.textDim)
                .padding(.top, 3)

            Text(entry.text)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textMuted)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Reasoning: \(entry.text)")
    }

    // MARK: System

    private var systemRow: some View {
        HStack(spacing: 8) {
            Hairline(color: Tokens.borderStrong)
                .frame(width: 18)
            Text(entry.text)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Hairline(color: Tokens.borderStrong)
                .frame(width: 18)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Previews

private struct TranscriptRowViewPreview: View {
    private let entries: [TranscriptEntry] = [
        TranscriptEntry(id: "1", role: .user, text: "Back up the vault and re-sync docs."),
        TranscriptEntry(id: "2", role: .assistant,
                        text: "Snapshotting the vault first, then I'll diff the `docs/` tree.\n\n1. `rsync` the vault\n2. Diff `docs/`\n\n> Nothing is deleted yet."),
        TranscriptEntry(id: "3", role: .tool,
                        text: "bash · rsync -a ~/vault/ ~/backup/vault/ · 0.8s"),
        TranscriptEntry(id: "4", role: .system, text: "Turn interrupted by you"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    TranscriptRowView(entry: entry)
                }
            }
            .padding(20)
            .frame(width: Geometry.conversationMeasure, alignment: .leading)
        }
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#Preview("Transcript rows") {
    TranscriptRowViewPreview()
}
