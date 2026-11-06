#if os(macOS)
import AppKit
import SwiftUI

/// The Mac composer's editor: a real `NSTextView`.
///
/// `TextField(axis: .vertical)` could grow with its text, but it could not break a line **where
/// the caret is**: it exposes no selection, and once a key handler has seen ⌘-less Return, returning
/// `.ignored` does not hand the key back — so the break had to be appended to the binding, which
/// always landed at the end of the draft.
///
/// A text view inserts at the caret, which is the entire requirement. Return is intercepted here
/// (it sends); Shift+Return and ⌥⇧⏎ are left to AppKit, which inserts the break at the selection the
/// way every other field on the platform does.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var fontSize: CGFloat
    /// The one-line floor and the ceiling where the field starts scrolling inside itself.
    var minHeight: CGFloat
    var maxHeight: CGFloat
    /// False while the composer has nothing to send into (no bot, no session): the field must not
    /// take keystrokes it would then throw away.
    var isEditable: Bool
    var onSend: () -> Void
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Smart quotes and dashes rewrite the user's ports, flags and paths.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Self.nsFont(size: fontSize)
        textView.textColor = NSColor(Tokens.textPrimary)
        textView.insertionPointColor = NSColor(Tokens.accent)
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: maxHeight)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        DispatchQueue.main.async { context.coordinator.resize(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The parent carries the newest closures and sizes; the coordinator only lives as long as
        // the view does.
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }

        if textView.string != text {
            // A dictation transcript, a cleared draft after a send, a restored per-bot draft.
            let caret = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
            context.coordinator.resize(textView)
        }

        textView.isEditable = isEditable

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    static func nsFont(size: CGFloat) -> NSFont {
        NSFont(name: "Inter", size: size) ?? .systemFont(ofSize: size)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            resize(view)
        }

        func textViewDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// Return sends; Shift+Return falls through to AppKit, which inserts the break at the caret.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) { return false }
            parent.onSend()
            return true
        }

        /// Report the height the text needs, clamped, so the card grows by a line at a time instead
        /// of jumping to a fixed size.
        func resize(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            let height = min(max(used, parent.minHeight), parent.maxHeight)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(height) }
        }
    }
}
#endif
