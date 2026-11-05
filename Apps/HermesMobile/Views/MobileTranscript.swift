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

    /// A tool entry restored from the host's transcript projection.
    ///
    /// The projection carries one line — `bash · rsync … · 0.8s · exit 0` — so the name is
    /// the token before the first separator. Labelling every row "tool" (what this used to
    /// do) threw away the only identifying word the row has.
    private var toolResult: some View {
        let parsed = MobileToolRow.parse(entry.text)
        return MobileToolRow(name: parsed.name,
                             summary: parsed.summary,
                             isRunning: false,
                             durationMS: nil)
    }

    private var systemNote: some View {
        Text(entry.text)
            .font(TypeScale.font(TypeScale.sm))
            .foregroundStyle(Tokens.textDim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

// MARK: - Tool card

/// One tool call, live or restored.
///
/// The name is always a real name: `tool.start`'s `name` for a live call, the projection's
/// leading token for a restored one. Output is drawn only when the caller supplies it
/// (`showToolOutput` and a non-empty result), so the card never claims "No output." about
/// a tool it simply chose not to show. Long output scrolls inside the card rather than
/// pushing the answer off screen.
struct MobileToolRow: View {
    let name: String
    var summary: String? = nil
    var output: String? = nil
    var isRunning: Bool = false
    var durationMS: Int? = nil

    @State private var expanded = false

    /// Never an empty box: the disclosure only exists when there is something behind it.
    private var shownOutput: String? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded, let shownOutput {
                Hairline()
                Text(shownOutput)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                            .fill(Tokens.sheetInset)
                    )
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .cardSurface()
        .animation(Motion.toolCard, value: expanded)
    }

    private var header: some View {
        Button {
            guard shownOutput != nil else { return }
            Haptics.selection()
            withAnimation(Motion.toolCard) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                statusGlyph

                Text(name)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(Tokens.mono)
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let durationText {
                    Text(durationText)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.textDim)
                        .fixedSize()
                }

                if shownOutput != nil {
                    DisclosureGlyph(expanded: expanded)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(shownOutput == nil ? "" : (expanded ? "Collapse tool output" : "Expand tool output"))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if isRunning {
            SpinningRing(color: Tokens.accent, size: 11, lineWidth: 1.5)
                .frame(width: 14, height: 14)
        } else {
            ZStack {
                Circle().fill(Tokens.controlActive)
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Tokens.textMuted)
            }
            .frame(width: 14, height: 14)
        }
    }

    private var durationText: String? {
        guard let durationMS else { return nil }
        if durationMS < 1_000 { return "\(max(0, durationMS)) ms" }
        let seconds = Double(durationMS) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        let rest = whole % 60
        return rest == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(rest)s"
    }

    private var accessibilityText: String {
        var parts = ["Tool", name, isRunning ? "running" : "done"]
        if let summary, !summary.isEmpty { parts.append(summary) }
        if let durationText { parts.append(durationText) }
        return parts.joined(separator: ", ")
    }

    // MARK: Parsing a restored row

    /// `bash · rsync -a ~/vault/ · 0.8s · exit 0` → (`bash`, `rsync -a ~/vault/ · 0.8s · exit 0`).
    ///
    /// A name is a single token; anything with a space in it is prose and stays in the
    /// summary, so a projection line that carries no name is labelled "Tool" rather than
    /// slicing a sentence in half.
    static func parse(_ text: String) -> (name: String, summary: String?) {
        let parts = text.components(separatedBy: " · ")
        let head = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isName = !head.isEmpty
            && head.count <= 32
            && !head.contains(" ")
            && !head.contains("\n")

        guard isName else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("Tool", trimmed.isEmpty ? nil : trimmed)
        }

        let rest = parts.dropFirst().joined(separator: " · ")
        return (head, rest.isEmpty ? nil : rest)
    }
}

// MARK: - Reasoning

/// The model's thinking, as a secondary block.
///
/// Collapsed by default and recessed behind the answer: reasoning is context for why the
/// reply says what it says, not the reply itself. It only exists when the host streamed
/// `thinking.delta` text *and* the user asked for it in Settings.
struct MobileReasoningBlock: View {
    let text: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(Motion.toolCard) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)

                    Text("Reasoning")
                        .font(TypeScale.font(TypeScale.label, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)

                    Spacer(minLength: 8)

                    DisclosureGlyph(expanded: expanded)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reasoning")
            .accessibilityHint(expanded ? "Collapse reasoning" : "Expand reasoning")

            if expanded {
                Text(text)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textMuted)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.sheetInset)
        )
        .hairlineBorder()
        .animation(Motion.toolCard, value: expanded)
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
                                                       text: "bash · rsync -a ~/vault/ ~/backup/vault/ · 0.8s · exit 0"))
            MobileTranscriptRow(entry: TranscriptEntry(id: "4",
                                                       role: .system,
                                                       text: "Session resumed from history."))
        }
        .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Tool + reasoning") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            MobileReasoningBlock(text: "The vault is large; a dry-run first keeps the diff small. Then rsync with --delete only after the diff is reviewed.")
            MobileToolRow(name: "read_file",
                          summary: "Sources/HermesKit/GatewayClient.swift",
                          output: "public struct Bot: Identifiable, Hashable, Sendable { … }",
                          durationMS: 240)
            MobileToolRow(name: "bash",
                          summary: "swift build",
                          isRunning: true)
        }
        .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Empty conversation") {
    MobileTranscriptEmpty(title: "Cody")
        .frame(maxHeight: .infinity)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
