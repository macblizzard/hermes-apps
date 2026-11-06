import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The message field.
///
/// It owns no state but its focus: the draft is the caller's binding, so a screen can
/// restore it per session and keep a failed send in place. `onSend` fires only when the
/// field has something to send; the screen clears the draft on success. While a turn is
/// running the send control becomes an interrupt, which is the contract `GatewayClient`
/// exposes (`submit` / `interrupt`, never both at once).
public struct Composer: View {
    @Binding private var text: String

    private let placeholder: String
    private let isSending: Bool
    private let isDisabled: Bool
    private let queuedCount: Int
    private let hasAttachments: Bool
    private let showsAttach: Bool
    private let showsMic: Bool
    private let hint: String?
    private let onSend: () -> Void
    private let onAttach: (() -> Void)?
    private let onMic: (() -> Void)?
    private let onInterrupt: (() -> Void)?
    /// A popover the paperclip itself anchors, rather than one hung off the whole card.
    ///
    /// The Mac's attach menu is a two-item popover, and presenting it from the composer's outer
    /// frame put it under the *field* — nowhere near the clip that opened it. Both halves are
    /// optional so the phone, which pushes a sheet, passes neither.
    private let attachPopoverPresented: Binding<Bool>?
    private let attachPopoverContent: AnyView?

    /// The microphone's own presentation, supplied by the caller because only the recording
    /// controller knows whether it is idle, listening or transcribing. It is drawn immediately
    /// left of the send arrow — the phone's order — instead of on a separate line above the card.
    private let micSystemImage: String
    private let micTint: Color?
    private let micAccessibilityLabel: String
    private let isMicEnabled: Bool

    @FocusState private var focused: Bool

    #if os(macOS)
    /// The text view reports its own first-responder state: `@FocusState` cannot see an
    /// `NSViewRepresentable`, and the border colour is driven by focus.
    @State private var editorFocused = false
    /// The height the editor asks for, so the card grows a line at a time.
    @State private var editorHeight: CGFloat = 22
    #endif

    public init(text: Binding<String>,
                placeholder: String = "Ask Hermes anything",
                isSending: Bool = false,
                isDisabled: Bool = false,
                queuedCount: Int = 0,
                hasAttachments: Bool = false,
                showsAttach: Bool = true,
                showsMic: Bool = true,
                micSystemImage: String = "mic",
                micTint: Color? = nil,
                micAccessibilityLabel: String = "Record a voice message",
                isMicEnabled: Bool = true,
                hint: String? = Composer.defaultHint,
                onSend: @escaping () -> Void,
                onAttach: (() -> Void)? = nil,
                onMic: (() -> Void)? = nil,
                onInterrupt: (() -> Void)? = nil,
                attachPopoverPresented: Binding<Bool>? = nil,
                attachPopoverContent: AnyView? = nil) {
        _text = text
        self.placeholder = placeholder
        self.isSending = isSending
        self.isDisabled = isDisabled
        self.queuedCount = queuedCount
        self.hasAttachments = hasAttachments
        self.showsAttach = showsAttach
        self.showsMic = showsMic
        self.micSystemImage = micSystemImage
        self.micTint = micTint
        self.micAccessibilityLabel = micAccessibilityLabel
        self.isMicEnabled = isMicEnabled
        self.hint = hint
        self.onSend = onSend
        self.onAttach = onAttach
        self.onMic = onMic
        self.onInterrupt = onInterrupt
        self.attachPopoverPresented = attachPopoverPresented
        self.attachPopoverContent = attachPopoverContent
    }

    /// The desktop hint line, in OpenBot's own words. The phone has no hint line.
    #if os(macOS)
    public static let defaultHint: String? = "⏎ send · ⇧⏎ newline · ⌘K commands"
    #else
    public static let defaultHint: String? = nil
    #endif

    #if os(iOS)
    private var controlSide: CGFloat { 32 }
    private var glyphSize: CGFloat { 12 }
    #else
    private var controlSide: CGFloat { 26 }
    private var glyphSize: CGFloat { 11 }
    #endif

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pending attachment is sendable on its own: a file with no comment is a complete message,
    /// and disabling the arrow there made the attach feature look broken.
    private var canSend: Bool {
        !isDisabled && !isSending && (!trimmed.isEmpty || hasAttachments)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if queuedCount > 0 {
                StatusChip.queued(queuedCount)
                    .padding(.leading, 2)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if showsAttach {
                    attachControl
                }

                field
                    .frame(minHeight: controlSide - 4)

                // The microphone belongs beside the send arrow: one row of controls, and the
                // control that ends a message next to the one that starts it.
                if showsMic {
                    micControl
                }

                if isSending, let onInterrupt {
                    interruptButton(onInterrupt)
                } else {
                    sendButton
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, hint == nil ? 8 : 2)

            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                    .accessibilityHidden(true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(isFieldFocused ? Tokens.borderFocus : Tokens.borderStrong, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.6 : 1)
    }

    /// The border's focus state. The Mac's editor is an `NSTextView` and reports its own first
    /// responder; the phone keeps `@FocusState`.
    private var isFieldFocused: Bool {
        #if os(macOS)
        editorFocused
        #else
        focused
        #endif
    }

    // MARK: Field

    private var baseField: some View {
        TextField("",
                  text: $text,
                  prompt: Text(placeholder).foregroundColor(Tokens.textPlaceholder),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(TypeScale.font(TypeScale.chatBody))
            .foregroundStyle(Tokens.textPrimary)
            .tint(Tokens.accent)
            .lineLimit(1...8)
            .focused($focused)
            .padding(.vertical, 6)
            .submitLabel(.send)
            .accessibilityLabel(placeholder)
            .disabled(isDisabled)
    }

    /// On the Mac the field is a real text view (see `ComposerTextView`), so Return sends and
    /// Shift+Return breaks the line *at the caret* — the platform's own insert, not an append.
    private var field: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(TypeScale.font(TypeScale.chatBody))
                    .foregroundStyle(Tokens.textPlaceholder)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ComposerTextView(text: $text,
                             isFocused: $editorFocused,
                             fontSize: TypeScale.chatBody,
                             minHeight: controlSide - 4,
                             // The design system's cap: past about eight lines the field scrolls
                             // inside itself instead of eating the conversation.
                             maxHeight: controlSide - 4 + TypeScale.chatLine * 7,
                             isEditable: !isDisabled,
                             onSend: { send() },
                             onHeightChange: { height in
                                 if abs(height - editorHeight) > 0.5 { editorHeight = height }
                             })
                .frame(height: editorHeight)
        }
        .frame(minHeight: controlSide - 4, alignment: .topLeading)
        .padding(.vertical, 6)
        #else
        baseField
            .onSubmit { send() }
        #endif
    }

    // MARK: Controls

    /// The paperclip. When a caller supplies a popover, it is anchored *here* — on the 26 pt
    /// button — so the menu drops from the clip instead of from the middle of the composer card.
    @ViewBuilder
    private var attachControl: some View {
        let button = OpenBotIconButton("paperclip",
                                       label: "Attach a file",
                                       size: .small,
                                       isDisabled: isDisabled) { onAttach?() }
        if let presented = attachPopoverPresented, let content = attachPopoverContent {
            button.popover(isPresented: presented, arrowEdge: .top) { content }
        } else {
            button
        }
    }

    /// The microphone. Drawn only when the caller supplied an action, so the phone's composer
    /// (which has its own voice affordances) is unchanged.
    @ViewBuilder
    private var micControl: some View {
        if let onMic {
            Button {
                Haptics.selection()
                onMic()
            } label: {
                Image(systemName: micSystemImage)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(micTint ?? Tokens.textSecondary)
                    .frame(width: controlSide, height: controlSide)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isDisabled || !isMicEnabled)
            .opacity(isMicEnabled ? 1 : 0.5)
            #if os(macOS)
            .help(micAccessibilityLabel)
            #endif
            .accessibilityLabel(micAccessibilityLabel)
            .accessibilityIdentifier("composer.mic")
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(canSend ? Tokens.textPrimary : Tokens.textDim)
                .frame(width: controlSide, height: controlSide)
                .background(
                    Circle().fill(canSend ? Tokens.accent : Tokens.controlActive)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canSend)
        .accessibilityLabel(isSending ? "Sending" : "Send message")
    }

    private func interruptButton(_ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact()
            action()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: glyphSize - 0.5, weight: .semibold))
                .foregroundStyle(Tokens.danger)
                .frame(width: controlSide, height: controlSide)
                .background(Circle().fill(Tokens.dangerSoft))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Interrupt the turn")
    }

    private func send() {
        guard canSend else { return }
        Haptics.impact()
        onSend()
    }
}

// MARK: - Previews

private struct ComposerPreviewHost: View {
    @State private var empty = ""
    @State private var typing = "Check whether the gateway ticket is single-use, then fix the retry."
    @State private var running = "Add a test for the rewind contract"

    var body: some View {
        VStack(spacing: 18) {
            Composer(text: $empty, onSend: {})
            Composer(text: $typing, onSend: {})
            Composer(text: $running, isSending: true, onSend: {}, onInterrupt: {})
            Composer(text: $empty, isDisabled: true, onSend: {})
            Composer(text: $typing, queuedCount: 2, onSend: {})
        }
        .padding(20)
        .frame(width: 520)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#Preview("Composer · states") {
    ComposerPreviewHost()
}
