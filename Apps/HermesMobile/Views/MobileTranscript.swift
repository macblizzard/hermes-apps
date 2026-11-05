import SwiftUI
import HermesKit
import HermesRender
import OpenBotUI

/// One row of the conversation.
///
/// The shapes are OpenBot's three: the user's message is a right-aligned tinted bubble,
/// the assistant is plain body text on the canvas (no bubble — a long answer in a bubble
/// is a wall inside a wall), and a tool result keeps the card the design system already
/// has. Markers come from the block layer so a list looks the same everywhere.
struct MobileTranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            userBubble
        case .assistant:
            assistant
        case .tool:
            toolResult
        case .system:
            systemNote
        }
    }

    // MARK: User

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 44)
            Text(entry.text)
                .font(TypeScale.font(TypeScale.chatBody))
                .lineSpacing(TypeScale.chatLineSpacing)
                .foregroundStyle(Tokens.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .fill(Tokens.accentSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Assistant

    private var assistant: some View {
        MobileMarkdownText(blocks: IncrementalMarkdown.parse(entry.text))
            .textSelection(.enabled)
            .accessibilityLabel(entry.text)
    }

    private var toolResult: some View {
        ToolCard(name: "tool",
                 summary: firstLine(of: entry.text),
                 status: .done,
                 output: entry.text)
    }

    private var systemNote: some View {
        Text(entry.text)
            .font(TypeScale.font(TypeScale.sm))
            .foregroundStyle(Tokens.textDim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private func firstLine(of text: String) -> String? {
        guard let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }
}

// MARK: - Empty state

/// An empty conversation is a prompt, not an apology.
struct MobileTranscriptEmpty: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Avatar(title, size: .hero, presence: .idle)
            Text(title)
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("Ask anything. Approvals show up here the moment Hermes needs one.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
    }
}

// MARK: - Previews

#Preview("Transcript rows") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            MobileTranscriptRow(entry: TranscriptEntry(id: "1",
                                                       role: .user,
                                                       text: "Back up the vault, then re-sync the docs tree."))
            MobileTranscriptRow(entry: TranscriptEntry(id: "2",
                                                       role: .assistant,
                                                       text: "Snapshotting the vault first.\n\n- `restic backup ~/vault`\n- then a **dry-run** diff of `docs/`"))
            MobileTranscriptRow(entry: TranscriptEntry(id: "3",
                                                       role: .tool,
                                                       text: "repo 8f21c1a opened\nsnapshot 41e2 saved · 118 MB"))
            MobileTranscriptRow(entry: TranscriptEntry(id: "4",
                                                       role: .system,
                                                       text: "Session resumed from history."))
        }
        .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Empty conversation") {
    MobileTranscriptEmpty(title: "Vault backup + docs sync")
        .frame(maxHeight: .infinity)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
