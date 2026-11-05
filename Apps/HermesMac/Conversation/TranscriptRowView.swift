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

    var body: some View {
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
                .lineSpacing(4)
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
        MarkdownTextView(text: entry.text)
            .accessibilityLabel("Hermes said: \(entry.text)")
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
