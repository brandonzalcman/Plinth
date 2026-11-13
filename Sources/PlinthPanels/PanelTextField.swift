import SwiftUI
import AppKit

/// Keys a panel's text field hands to its panel instead of acting on them.
public enum PanelKey: Equatable, Sendable {
    case up
    case down
    /// Return or Enter, with whichever of these modifiers were held.
    case submit(option: Bool, command: Bool, shift: Bool)
    case escape
}

/// A borderless single-line AppKit text field.
///
/// SwiftUI's `TextField` on macOS swallows arrow keys and Escape in the field editor before
/// `.onKeyPress` reliably sees them, so the panels use this instead. Keys arrive three ways:
/// - arrows, Return, ⌥Return, ⇧Return and Escape come through the field editor's `doCommandBy`,
///   which is only called once an input method has finished composing;
/// - ⌘Return is a key equivalent that never reaches the field editor, so a local key monitor
///   catches it while this field is being edited;
/// - everything else is ordinary typing.
public struct PanelTextField: NSViewRepresentable {
    @Binding private var text: String
    private var placeholder: String
    private var fontSize: CGFloat
    private var textColor: Color
    private var placeholderColor: Color
    private var accent: Color
    private var label: String
    private var focusOnAppear: Bool
    private var selectAllOnFocus: Bool
    private var onKey: (PanelKey) -> Bool

    /// - Parameter onKey: return true when the key was used; false lets the field do its default.
    public init(text: Binding<String>, placeholder: String, fontSize: CGFloat = 13,
                textColor: Color, placeholderColor: Color, accent: Color, label: String,
                focusOnAppear: Bool = true, selectAllOnFocus: Bool = true,
                onKey: @escaping (PanelKey) -> Bool) {
        self._text = text; self.placeholder = placeholder; self.fontSize = fontSize
        self.textColor = textColor; self.placeholderColor = placeholderColor; self.accent = accent
        self.label = label; self.focusOnAppear = focusOnAppear; self.selectAllOnFocus = selectAllOnFocus
        self.onKey = onKey
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: fontSize)
        field.stringValue = text
        field.delegate = context.coordinator
        field.wantsInitialFocus = focusOnAppear
        field.selectsAllOnFocus = selectAllOnFocus
        field.onCommandReturn = { [weak coordinator = context.coordinator] in
            _ = coordinator?.parent.onKey(.submit(option: false, command: true, shift: false))
        }
        apply(to: field)
        return field
    }

    public func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never write back mid-composition, and never when equal: both would move the caret.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing, field.stringValue != text { field.stringValue = text }
        apply(to: field)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let height = nsView.intrinsicContentSize.height
        let width = proposal.width ?? 240
        return CGSize(width: width.isFinite ? max(width, 20) : 240, height: height)
    }

    private func apply(to field: NSTextField) {
        let font = NSFont.systemFont(ofSize: fontSize)
        if field.font != font { field.font = font }
        field.textColor = NSColor(textColor)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(placeholderColor), .font: font])
        field.setAccessibilityLabel(label)
        (field as? Field)?.caretColor = NSColor(accent)
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelTextField
        init(_ parent: PanelTextField) { self.parent = parent }

        public func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥Return arrives as insertNewlineIgnoringFieldEditor; the live flags cover every case.
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                let option = flags.contains(.option) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                _ = parent.onKey(.submit(option: option, command: flags.contains(.command), shift: flags.contains(.shift)))
                // Always claim Return so the field never ends editing or inserts a line break.
                return true
            default:
                return false
            }
        }
    }

    final class Field: NSTextField {
        var wantsInitialFocus = false
        var selectsAllOnFocus = true
        var caretColor: NSColor?
        var onCommandReturn: (() -> Void)?
        private var didFocus = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let editor = self.currentEditor() as? NSTextView, window.firstResponder === editor,
                      event.keyCode == 36 || event.keyCode == 76,
                      event.modifierFlags.contains(.command),
                      !editor.hasMarkedText()
                else { return event }
                self.onCommandReturn?()
                return nil
            }
            guard wantsInitialFocus, !didFocus else { return }
            didFocus = true
            // Next turn of the run loop: the hosting view is still being installed at this point.
            DispatchQueue.main.async { [weak self] in self?.takeFocus() }
        }

        private func takeFocus() {
            guard let window else { return }
            guard window.makeFirstResponder(self), let editor = currentEditor() else { return }
            if selectsAllOnFocus {
                editor.selectAll(nil)
            } else {
                editor.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
            }
        }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok, let caretColor, let editor = currentEditor() as? NSTextView {
                editor.insertionPointColor = caretColor
            }
            return ok
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
