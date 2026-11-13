import SwiftUI
import AppKit
import PlinthPanels
import PlinthSettings

/// Palette and accent for the Settings window, resolved once at the root from the colour scheme.
struct SettingsTheme {
    var p: PanelPalette
    var accent: Color
    var amber: Color
    var danger: Color
}

private struct SettingsThemeKey: EnvironmentKey {
    static let defaultValue = SettingsTheme(p: PanelPalette(.light), accent: PanelPalette.sky,
                                            amber: Color(red: 0.70, green: 0.45, blue: 0.05), danger: Color(red: 0.75, green: 0.2, blue: 0.2))
}

extension EnvironmentValues {
    var settingsTheme: SettingsTheme {
        get { self[SettingsThemeKey.self] }
        set { self[SettingsThemeKey.self] = newValue }
    }
}

extension SettingsStore {
    /// A two-way binding to one field; writes go through `update`.
    @MainActor
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.value[keyPath: keyPath] }, set: { new in self.update { $0[keyPath: keyPath] = new } })
    }
}

// MARK: - Page and card

/// A section's scrolling page: a large title, then its cards.
struct SettingsPage<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var t

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(t.p.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(t.p.secondary)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
    }
}

/// A rounded group of rows, with an optional heading above it.
struct SettingsCard<Content: View>: View {
    var heading: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.settingsTheme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let heading {
                Text(heading.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(t.p.tertiary).padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.p.surface.opacity(0.78)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.p.border, lineWidth: 0.5))
        }
    }
}

/// A hairline between rows of a card.
struct SettingsDivider: View {
    @Environment(\.settingsTheme) private var t
    var body: some View { Rectangle().fill(t.p.divider).frame(height: 0.5).padding(.leading, 14) }
}

// MARK: - Rows

/// Title and optional caption on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var caption: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.settingsTheme) private var t

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(t.p.primary)
                if let caption {
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(t.p.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row whose control is an on/off switch tinted with the accent.
struct SettingsToggleRow: View {
    var title: String
    var caption: String? = nil
    @Binding var isOn: Bool
    @Environment(\.settingsTheme) private var t

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(t.accent)
        }
    }
}

/// A caption-only line inside a card (explanations, results, hints).
struct SettingsNote: View {
    enum Tone { case plain, good, warning, error }
    var text: String
    var tone: Tone = .plain
    @Environment(\.settingsTheme) private var t

    var body: some View {
        let color: Color = switch tone {
        case .plain: t.p.secondary
        case .good: t.accent
        case .warning: t.amber
        case .error: t.danger
        }
        Text(text).font(.system(size: 11.5)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Controls

/// A compact text button in the style of the panel pills: accent-filled, or quiet with a soft fill.
struct SettingsButton: View {
    enum Style { case accent, quiet, destructive }
    var title: String
    var systemImage: String? = nil
    var style: Style = .quiet
    var action: () -> Void
    @Environment(\.settingsTheme) private var t
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let filled = style != .quiet
        let fill: Color = switch style {
        case .accent: t.accent
        case .destructive: t.danger
        case .quiet: hovered ? t.p.hover : t.p.fill
        }
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)).accessibilityHidden(true) }
                Text(title).font(.system(size: 12, weight: filled ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(filled ? t.p.onAccent : t.p.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(fill).opacity(filled && hovered ? 0.88 : 1))
            .overlay(Capsule().strokeBorder(filled ? .clear : t.p.border, lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A pill-shaped segmented control for a small enum.
struct SettingsSegmented<Value: Hashable>: View {
    var label: String
    var options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.settingsTheme) private var t
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, name) = options[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(name).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(on ? t.p.onAccent : t.p.primary)
                        .padding(.horizontal, 11).frame(height: 24)
                        .background(Capsule().fill(on ? t.accent : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .fixedSize()
        .padding(2)
        .background(Capsule().fill(t.p.fill))
        .overlay(Capsule().strokeBorder(t.p.border, lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A menu picker drawn as a pill.
struct SettingsMenuPicker<Value: Hashable>: View {
    var label: String
    var options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.settingsTheme) private var t

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { selection = options[i].0 }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(t.p.primary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(t.p.secondary)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(t.p.fill))
            .overlay(Capsule().strokeBorder(t.p.border, lineWidth: 0.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(label)
    }
}

/// A rounded text field in the style of the command bar.
struct SettingsTextField: View {
    var label: String
    var placeholder: String
    @Binding var text: String
    var width: CGFloat = 260
    @Environment(\.settingsTheme) private var t
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(t.p.primary)
            .autocorrectionDisabled()
            .padding(.horizontal, 12).frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.p.inputFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(t.p.border, lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(label)
    }
}

/// − value + with a "Reset" affordance that appears when the value differs from its default.
struct SettingsStepper: View {
    var label: String
    var valueText: String
    var isDefault: Bool
    var canDecrement: Bool
    var canIncrement: Bool
    var decrement: () -> Void
    var increment: () -> Void
    var reset: () -> Void
    @Environment(\.settingsTheme) private var t

    var body: some View {
        HStack(spacing: 8) {
            if !isDefault {
                Button("Reset", action: reset).buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(t.accent).accessibilityLabel("Reset \(label) to default")
            }
            HStack(spacing: 0) {
                stepButton("minus", enabled: canDecrement, name: "Decrease \(label)", action: decrement)
                Text(valueText).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(t.p.primary)
                    .frame(minWidth: 54).accessibilityHidden(true)
                stepButton("plus", enabled: canIncrement, name: "Increase \(label)", action: increment)
            }
            .padding(2)
            .background(Capsule().fill(t.p.fill))
            .overlay(Capsule().strokeBorder(t.p.border, lineWidth: 0.5))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
    }

    private func stepButton(_ symbol: String, enabled: Bool, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(t.p.primary)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35).accessibilityLabel(name)
    }
}
