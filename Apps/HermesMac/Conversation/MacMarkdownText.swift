import HermesRender
import OpenBotUI
import SwiftUI

/// Draws the `AttributedString` the block layer compiled, run by run.
///
/// `HermesRender` owns *semantics* (`BoldAttribute`, `InlineCodeAttribute`,
/// `CodeTokenAttribute`…), not colours; this is where a run's meaning becomes type. Two
/// choices worth stating:
///
/// - Runs are concatenated as `Text` values rather than converted into a second
///   `AttributedString` carrying SwiftUI attributes. `Text + Text` is the oldest, most
///   stable way to mix fonts inside one line on macOS and it cannot drift with an SDK's
///   attribute-scope rules.
/// - Nothing is hardcoded: sizes come from `ChatTextMetrics` / `TypeScale`, colours from
///   `Tokens`.
struct MacMarkdownText: View {
    let attributed: AttributedString
    var size: CGFloat = TypeScale.chatBody
    var weight: Font.Weight = .regular
    var color: Color = Tokens.textSecondary
    var codeSize: CGFloat = ChatTextMetrics.macOS.codeSize
    var isCodeBlock: Bool = false
    var lineSpacing: CGFloat = TypeScale.chatLineSpacing

    var body: some View {
        renderedText
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(String(attributed.characters))
    }

    /// One `Text` per run, styled from the run's hermes attributes.
    private var renderedText: Text {
        var result = Text("")
        for run in attributed.runs {
            let slice = String(attributed.characters[run.range])
            guard !slice.isEmpty else { continue }

            let attributes = run.attributes
            let isBold = attributes[BoldAttribute.self] == true
            let isItalic = attributes[ItalicAttribute.self] == true
            let isInlineCode = attributes[InlineCodeAttribute.self] == true
            let isStruck = attributes[StrikethroughAttribute.self] == true
            let blockLanguage = attributes[CodeBlockAttribute.self]
            let token = attributes[CodeTokenAttribute.self]
            let isLink = run.link != nil

            let isMonospaced = isCodeBlock || isInlineCode || blockLanguage != nil

            var font = Font.system(size: isMonospaced ? codeSize : size,
                                    weight: isBold ? .semibold : weight,
                                    design: isMonospaced ? .monospaced : .default)
            if isItalic {
                font = font.italic()
            }

            var segment = AttributedString(slice)
            if let url = run.link { segment.link = url }
            var piece = Text(segment).font(font)

            if isLink {
                piece = piece.foregroundColor(Tokens.accentText).underline()
            } else if token != nil {
                piece = piece.foregroundColor(MacCodePalette.color(for: token))
            } else if isMonospaced {
                piece = piece.foregroundColor(isCodeBlock ? Tokens.textSecondary : Tokens.textPrimary)
            } else {
                piece = piece.foregroundColor(color)
            }

            if isStruck {
                piece = piece.strikethrough()
            }

            result = result + piece
        }
        return result
    }
}

// MARK: - Previews

private struct MacMarkdownTextPreview: View {
    private let sample = InlineMarkdown.attributedString(
        "Snapshotting the **vault** first, then I'll diff the `docs/` tree — ~~nothing deleted~~, see [the plan](https://example.com/plan)."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MacMarkdownText(attributed: sample)
            MacMarkdownText(attributed: InlineMarkdown.attributedString("a single *quiet* line"),
                            size: TypeScale.label,
                            color: Tokens.textMuted)
        }
        .padding(20)
        .frame(width: Geometry.conversationMeasure)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#Preview("Markdown text") {
    MacMarkdownTextPreview()
}
