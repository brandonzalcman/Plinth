import SwiftUI
import AppKit

/// A compact find-in-page strip. Typing calls `onFind(text, false)` on every change (an empty
/// string means "clear the highlights"); Return finds the next match, ⇧Return the previous one.
/// The shell sets `notFound` after a search comes back empty; the view clears it when the text changes.
public struct FindBarView: View {
    private let accent: Color
    private let onFind: (String, Bool) -> Void
    private let onDismiss: () -> Void
    @Binding private var notFound: Bool
    @State private var text: String
    @Environment(\.colorScheme) private var scheme

    public init(accent: Color,
                initialText: String = "",
                notFound: Binding<Bool> = .constant(false),
                onFind: @escaping (String, _ backwards: Bool) -> Void,
                onDismiss: @escaping () -> Void) {
        self.accent = accent; self.onFind = onFind; self.onDismiss = onDismiss
        _notFound = notFound
        _text = State(initialValue: initialText)
    }

    private var showsNotFound: Bool { notFound && !text.isEmpty }

    public var body: some View {
        let palette = PanelPalette(scheme)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showsNotFound ? palette.notice : palette.secondary)
                .accessibilityHidden(true)
            PanelTextField(text: $text,
                           placeholder: "Find on page",
                           fontSize: 13,
                           textColor: showsNotFound ? palette.notice : palette.primary,
                           placeholderColor: palette.tertiary,
                           accent: accent,
                           label: "Find on page",
                           focusOnAppear: true,
                           selectAllOnFocus: true,
                           onKey: handle)
            if showsNotFound {
                Text("Not found")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.notice)
                    .fixedSize()
                    .transition(.opacity)
            }
            button("chevron.up", label: "Previous match", palette: palette, disabled: text.isEmpty || showsNotFound) {
                onFind(text, true)
            }
            button("chevron.down", label: "Next match", palette: palette, disabled: text.isEmpty || showsNotFound) {
                onFind(text, false)
            }
            Rectangle().fill(palette.divider).frame(width: 1, height: 18)
            button("xmark", label: "Close find", palette: palette, disabled: false, action: onDismiss)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: 340, height: 44)
        .panelChrome(cornerRadius: 14)
        .onAppear {
            if !text.isEmpty { onFind(text, false) }
        }
        .onChange(of: text) {
            if notFound { notFound = false }
            onFind(text, false)
        }
        .onChange(of: notFound) {
            if showsNotFound { AccessibilityNotification.Announcement("Not found").post() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find on page")
    }

    private func handle(_ key: PanelKey) -> Bool {
        switch key {
        case .submit(_, _, let shift):
            if !text.isEmpty { onFind(text, shift) }
            return true
        case .escape:
            onDismiss()
            return true
        case .up, .down:
            return false
        }
    }

    private func button(_ symbol: String, label: String, palette: PanelPalette, disabled: Bool,
                        action: @escaping () -> Void) -> some View {
        FindBarButton(symbol: symbol, label: label, palette: palette, action: action)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
    }
}

private struct FindBarButton: View {
    var symbol: String
    var label: String
    var palette: PanelPalette
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? palette.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
