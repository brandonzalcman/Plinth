import SwiftUI
import AppKit
import PlinthModel

/// One choice in the ask panel's scope picker, e.g. `.page` / "This page",
/// `.site` / "All Docs pages (3)", `.split` / "Compare split".
public struct AskScopeOption: Identifiable, Equatable, Sendable {
    public var scope: AskScope
    public var label: String
    public var id: AskScope { scope }

    public init(scope: AskScope, label: String) {
        self.scope = scope; self.label = label
    }
}

/// The "ask page / ask site" panel (⌘J). Sits above the bar like the command bar: the question
/// field is at the bottom edge, the scope picker just above it, and the answer grows upward from
/// there, scrolling once it reaches `maxAnswerHeight`.
///
/// - Return in the field calls `onAsk` with the trimmed question (ignored when empty).
/// - Escape, or a click outside the panel, calls `onDismiss`.
/// - While `isStreaming` a Stop button replaces the Ask button and calls `onStop`.
/// - When `message` is set (AI turned off, not available on this Mac, a failed request) it is
///   shown instead of the answer; with `canTurnOn` it carries a "Turn On" button for `onTurnOn`.
///
/// `answer` is the whole answer so far; inline Markdown (bold, italics, code, links) is rendered.
/// The scope picker is hidden when there is only one option. Fixed width: `AskPanelView.width`.
public struct AskPanelView: View {
    private let scopes: [AskScopeOption]
    @Binding private var selectedScope: AskScope
    private let answer: String
    private let isStreaming: Bool
    private let message: String?
    private let canTurnOn: Bool
    private let accent: Color
    private let onAsk: (String) -> Void
    private let onStop: () -> Void
    private let onTurnOn: () -> Void
    private let onDismiss: () -> Void

    @State private var question: String
    @State private var answerHeight: CGFloat = 0
    @State private var hoveredScope: AskScope?
    @Environment(\.colorScheme) private var scheme

    public static let width: CGFloat = 560
    public static let maxAnswerHeight: CGFloat = 320

    public init(scopes: [AskScopeOption],
                selectedScope: Binding<AskScope>,
                answer: String,
                isStreaming: Bool,
                message: String?,
                canTurnOn: Bool,
                accent: Color,
                initialQuestion: String = "",
                onAsk: @escaping (String) -> Void,
                onStop: @escaping () -> Void,
                onTurnOn: @escaping () -> Void,
                onDismiss: @escaping () -> Void) {
        self.scopes = scopes; self._selectedScope = selectedScope; self.answer = answer
        self.isStreaming = isStreaming; self.message = message; self.canTurnOn = canTurnOn
        self.accent = accent; self.onAsk = onAsk; self.onStop = onStop; self.onTurnOn = onTurnOn
        self.onDismiss = onDismiss
        _question = State(initialValue: initialQuestion)
    }

    private var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasAnswer: Bool { !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsContent: Bool { message != nil || hasAnswer || isStreaming }

    private var placeholder: String {
        switch selectedScope {
        case .page: return "Ask about this page"
        case .site: return "Ask about these pages"
        case .split: return "Compare the two pages"
        }
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        VStack(spacing: 0) {
            if showsContent {
                Group {
                    if let message {
                        messageView(message, palette: palette)
                    } else if !hasAnswer {
                        thinking(palette: palette)
                    } else {
                        answerView(palette: palette)
                    }
                }
                .transition(.opacity)
                Rectangle().fill(palette.divider).frame(height: 1)
            }
            VStack(spacing: 0) {
                if scopes.count > 1 {
                    scopePicker(palette: palette)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    PanelTextField(text: $question,
                                   placeholder: placeholder,
                                   fontSize: 15,
                                   textColor: palette.primary,
                                   placeholderColor: palette.tertiary,
                                   accent: accent,
                                   label: placeholder,
                                   focusOnAppear: true,
                                   selectAllOnFocus: true,
                                   onKey: handle)
                    if isStreaming {
                        PanelPillButton(title: "Stop", systemImage: "stop.fill", style: .quiet, palette: palette, action: onStop)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.border))
                            .help("Stop answering")
                    } else {
                        askButton(palette: palette)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
            }
            .background(palette.inputFill)
        }
        .frame(width: Self.width)
        .panelChrome()
        .background(OutsideClickMonitor(onOutside: onDismiss))
        .animation(.easeOut(duration: 0.15), value: showsContent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask")
    }

    // MARK: Pieces

    private func scopePicker(palette: PanelPalette) -> some View {
        HStack(spacing: 8) {
            Text("Ask about")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.tertiary)
                .fixedSize()
            HStack(spacing: 2) {
                ForEach(scopes) { option in
                    let selected = option.scope == selectedScope
                    Button {
                        selectedScope = option.scope
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? palette.onAccent : palette.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? accent : (hoveredScope == option.scope ? palette.hover : Color.clear))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { hoveredScope = option.scope } else if hoveredScope == option.scope { hoveredScope = nil }
                    }
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.fill))
            .fixedSize()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask about")
    }

    private func askButton(palette: PanelPalette) -> some View {
        let enabled = !trimmedQuestion.isEmpty
        return Button {
            if enabled { onAsk(trimmedQuestion) }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? palette.onAccent : palette.tertiary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(enabled ? accent : palette.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Ask (Return)")
        .accessibilityLabel("Ask")
    }

    private func thinking(palette: PanelPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.tertiary)
            ShimmerLine(width: nil, palette: palette)
            ShimmerLine(width: 300, palette: palette)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }

    private func answerView(palette: PanelPalette) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.rendered(answer))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(palette.primary)
                        .tint(accent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if isStreaming {
                        Circle().fill(accent).frame(width: 6, height: 6).padding(.top, 6)
                            .accessibilityHidden(true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(answerHeight, 44), Self.maxAnswerHeight))
            .onChange(of: answer) {
                if isStreaming { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .accessibilityLabel("Answer")
    }

    private func messageView(_ text: String, palette: PanelPalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: canTurnOn ? "sparkles" : "exclamationmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canTurnOn {
                PanelPillButton(title: "Turn On", style: .accent(accent), palette: palette, action: onTurnOn)
                    .help("Turn on on-device AI")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    // MARK: Keys

    private func handle(_ key: PanelKey) -> Bool {
        switch key {
        case .submit:
            if !trimmedQuestion.isEmpty { onAsk(trimmedQuestion) }
            return true
        case .escape:
            onDismiss()
            return true
        case .up, .down:
            return false
        }
    }

    /// Inline Markdown, keeping line breaks. Falls back to the plain text if it does not parse.
    static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
