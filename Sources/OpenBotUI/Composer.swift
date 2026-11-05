import Foundation
import SwiftUI

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
    private let showsAttach: Bool
    private let showsMic: Bool
    private let hint: String?
    private let onSend: () -> Void
    private let onAttach: (() -> Void)?
    private let onMic: (() -> Void)?
    private let onInterrupt: (() -> Void)?

    @FocusState private var focused: Bool

    public init(text: Binding<String>,
                placeholder: String = "Ask Hermes anything",
                isSending: Bool = false,
                isDisabled: Bool = false,
                queuedCount: Int = 0,
                showsAttach: Bool = true,
                showsMic: Bool = true,
                hint: String? = Composer.defaultHint,
                onSend: @escaping () -> Void,
                onAttach: (() -> Void)? = nil,
                onMic: (() -> Void)? = nil,
                onInterrupt: (() -> Void)? = nil) {
        _text = text
        self.placeholder = placeholder
        self.isSending = isSending
        self.isDisabled = isDisabled
        self.queuedCount = queuedCount
        self.showsAttach = showsAttach
        self.showsMic = showsMic
        self.hint = hint
        self.onSend = onSend
        self.onAttach = onAttach
        self.onMic = onMic
        self.onInterrupt = onInterrupt
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

    private var canSend: Bool {
        !isDisabled && !isSending && !trimmed.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if queuedCount > 0 {
                StatusChip.queued(queuedCount)
                    .padding(.leading, 2)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if showsAttach {
                    OpenBotIconButton("paperclip",
                                      label: "Attach a file",
                                      size: .small,
                                      isDisabled: isDisabled) { onAttach?() }
                }

                field
                    .frame(minHeight: controlSide - 4)

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
                .strokeBorder(focused ? Tokens.borderFocus : Tokens.borderStrong, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.6 : 1)
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

    /// A multiline `TextField` submits only where the platform gives it a return key that
    /// means "done". On the Mac the return key is a newline, so the send is taken from
    /// the key press itself (Shift+Return stays a newline).
    private var field: some View {
        #if os(macOS)
        baseField
            // The no-modifier `onKeyPress(_:action:)` overload hands the closure no
            // `KeyPress`, so it cannot see the Shift modifier. The phases form does.
            .onKeyPress(phases: .down) { press in
                guard press.key == .return else { return .ignored }
                if press.modifiers.contains(.shift) { return .ignored }
                send()
                return .handled
            }
        #else
        baseField
            .onSubmit { send() }
        #endif
    }

    // MARK: Controls

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
