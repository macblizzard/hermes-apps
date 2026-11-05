import SwiftUI
import HermesRender
import OpenBotUI

/// Markdown, drawn the way OpenBot draws a message: 16 pt on a 22 pt line, one block
/// per paragraph, code in the mono face on the inset surface.
///
/// The block list comes from `HermesRender` (the block layer decides what is a paragraph,
/// a fence or a rule); this file is only the mapping from a `Block` to pixels. Inline
/// emphasis is built as concatenated `Text` rather than `AttributedString` because the
/// app needs the *run* font and colour, and a `Text` run keeps them through composition.
struct MobileMarkdownText: View {
    let blocks: [Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MobileMarkdownBlock(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MobileMarkdownBlock: View {
    let block: Block

    private var bodySize: CGFloat { TypeScale.chatBody }

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .lineSpacing(TypeScale.chatLineSpacing)

        case .heading(let level, let text):
            inline(text,
                   weight: .semibold,
                   size: bodySize + (level <= 1 ? 3 : 1),
                   color: Tokens.textPrimary)
                .lineSpacing(TypeScale.chatLineSpacing)
                .padding(.top, 2)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(TypeScale.font(bodySize))
                    .foregroundColor(Tokens.textDim)
                inline(text)
                    .lineSpacing(TypeScale.chatLineSpacing)
            }

        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(TypeScale.font(bodySize))
                    .foregroundColor(Tokens.textDim)
                inline(text)
                    .lineSpacing(TypeScale.chatLineSpacing)
            }

        case .code(_, let body, _):
            codeBlock(body)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Tokens.borderFocus)
                    .frame(width: 2)
                inline(text, color: Tokens.textMuted)
                    .italic()
                    .lineSpacing(TypeScale.chatLineSpacing)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Hairline(color: Tokens.borderGrouped)
                .padding(.vertical, 2)
        }
    }

    // MARK: Inline

    private func inline(_ source: String,
                        weight: Font.Weight = .regular,
                        size: CGFloat? = nil,
                        color: Color = Tokens.textSecondary) -> Text {
        let pointSize = size ?? bodySize
        var output = Text(verbatim: "")
        for span in InlineMarkdown.spans(source) {
            var piece = Text(span.text)
            if span.styles.contains(.code) {
                piece = piece
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(Tokens.accentText)
            } else {
                piece = piece
                    .font(TypeScale.font(pointSize, weight: weight))
                    .foregroundColor(color)
            }
            if span.styles.contains(.strong) { piece = piece.bold() }
            if span.styles.contains(.emphasis) { piece = piece.italic() }
            if span.styles.contains(.strikethrough) { piece = piece.strikethrough() }
            if span.link != nil {
                piece = piece.foregroundColor(Tokens.accentText).underline()
            }
            output = output + piece
        }
        return output
    }

    // MARK: Code

    private func codeBlock(_ body: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(body.isEmpty ? " " : body)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.sheetInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
    }
}

// MARK: - Streaming

/// The live assistant bubble.
///
/// The text arrives a token at a time; `IncrementalMarkdown` keeps the parsed prefix and
/// only re-parses the open tail, so a long answer does not re-parse itself on every frame.
/// The caret is the only motion, and it stops under Reduce Motion.
struct MobileStreamingBubble: View {
    let text: String

    @State private var markdown = IncrementalMarkdown()
    @State private var caretOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if markdown.blocks.isEmpty {
                MobileTypingIndicator()
            } else {
                MobileMarkdownText(blocks: markdown.blocks)
                    .textSelection(.enabled)
                caret
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { sync(text) }
        .onChange(of: text) { newValue in sync(newValue) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes is responding")
    }

    private var caret: some View {
        Capsule()
            .fill(Tokens.accent)
            .frame(width: 7, height: 16)
            .opacity(caretOn ? 0.2 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    caretOn = true
                }
            }
            .accessibilityHidden(true)
    }

    /// Append only the delta when the stream is a prefix extension (the normal case);
    /// start over if the host rewound or the session changed.
    private func sync(_ value: String) {
        if value.hasPrefix(markdown.source) {
            let delta = String(value.dropFirst(markdown.source.count))
            if !delta.isEmpty { markdown.append(delta) }
        } else {
            markdown = IncrementalMarkdown()
            markdown.append(value)
        }
    }
}

/// "Thinking" before the first token: a ring, not a fake bubble of dots.
struct MobileTypingIndicator: View {
    var body: some View {
        HStack(spacing: 7) {
            SpinningRing(color: Tokens.textMuted, size: 10, lineWidth: 1.5)
            Text("Thinking…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .accessibilityLabel("Hermes is thinking")
    }
}

// MARK: - Previews

#Preview("Markdown · assistant reply") {
    ScrollView {
        MobileMarkdownText(blocks: IncrementalMarkdown.parse("""
        Here is the **plan**, in order:

        1. Snapshot the vault with `restic`.
        2. Diff the docs tree against the last run.
        3. Only then touch anything.

        > Backups first, edits second.

        ```swift
        let snapshot = try await restic.snapshot(path: "~/vault")
        print(snapshot.id)
        ```

        - `--dry-run` is always safe
        - so is *reading* the log
        """))
        .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Streaming") {
    VStack(alignment: .leading, spacing: 20) {
        MobileStreamingBubble(text: "Snapshotting the vault first")
        MobileStreamingBubble(text: "")
        MobileTypingIndicator()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
