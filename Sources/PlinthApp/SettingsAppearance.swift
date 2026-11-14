import SwiftUI
import PlinthSettings

struct AppearanceSettingsView: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t
    private var settings: SettingsStore { app.settings }

    /// The same steps the page zoom commands use.
    static let brandAccents: [AccentChoice] = [.dusk, .meadow, .ember, .midnight, .mono]
    static let standardAccents: [AccentChoice] = AccentChoice.allCases.filter { !brandAccents.contains($0) }

    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    private var zoomIndex: Int {
        let z = settings.value.defaultZoom
        return Self.zoomSteps.indices.min { abs(Self.zoomSteps[$0] - z) < abs(Self.zoomSteps[$1] - z) } ?? 5
    }

    var body: some View {
        SettingsPage(title: "Appearance & Bar") {
            SettingsCard(heading: "Appearance") {
                SettingsRow(title: "Appearance", caption: appearanceCaption) {
                    SettingsMenuPicker(label: "Appearance",
                                       options: AppearanceChoice.allCases.map { ($0, $0.displayName) },
                                       selection: settings.binding(\.appearance))
                }
            }

            SettingsCard(heading: "Accent colour") {
                SettingsRow(title: "Accent", caption: "Used for the current page, buttons and switches. Applies immediately.") {
                    HStack(spacing: 9) {
                        ForEach(Self.standardAccents, id: \.self) { choice in swatch(choice) }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Brand colours", caption: "Unlock one for each level you reach, from Points & Levels.") {
                    HStack(spacing: 9) {
                        ForEach(Self.brandAccents, id: \.self) { choice in swatch(choice) }
                    }
                }
            }

            SettingsCard(heading: "Bar") {
                SettingsRow(title: "Fade pages to the shelf", caption: fadeCaption) {
                    SettingsMenuPicker(label: "Fade pages to the shelf",
                                       options: FadeBehavior.allCases.map { ($0, $0.displayName) },
                                       selection: settings.binding(\.fadeBehavior))
                }
            }

            SettingsCard(heading: "Pages") {
                SettingsRow(title: "Default page zoom", caption: "Applies to pages you open from now on.") {
                    HStack(spacing: 10) {
                        if zoomIndex != Self.zoomSteps.firstIndex(of: 1) {
                            Button("Reset") { settings.update { $0.defaultZoom = 1 } }.buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(t.accentText).fixedSize()
                                .accessibilityLabel("Reset default page zoom")
                        }
                        Slider(value: Binding(get: { Double(zoomIndex) }, set: { v in settings.update { s in s.defaultZoom = Self.zoomSteps[min(max(Int(v.rounded()), 0), Self.zoomSteps.count - 1)] } }),
                               in: 0...Double(Self.zoomSteps.count - 1), step: 1)
                            .frame(width: 130).tint(t.accent).accessibilityLabel("Default page zoom")
                        Text("\(Int((Self.zoomSteps[zoomIndex] * 100).rounded()))%").font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(t.p.primary).frame(width: 44, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Default font size", caption: "Applies to pages you open from now on.") {
                    SettingsStepper(label: "default font size", valueText: "\(settings.value.defaultFontSize) px",
                                    isDefault: settings.value.defaultFontSize == 16,
                                    canDecrement: settings.value.defaultFontSize > 9, canIncrement: settings.value.defaultFontSize < 72,
                                    decrement: { settings.update { $0.defaultFontSize = max(9, $0.defaultFontSize - 1) } },
                                    increment: { settings.update { $0.defaultFontSize = min(72, $0.defaultFontSize + 1) } },
                                    reset: { settings.update { $0.defaultFontSize = 16 } })
                }
                SettingsDivider()
                SettingsRow(title: "Minimum font size", caption: "Keeps tiny text readable. Applies to pages you open from now on.") {
                    SettingsStepper(label: "minimum font size", valueText: settings.value.minimumFontSize == 0 ? "None" : "\(settings.value.minimumFontSize) px",
                                    isDefault: settings.value.minimumFontSize == 0,
                                    canDecrement: settings.value.minimumFontSize > 0, canIncrement: settings.value.minimumFontSize < 36,
                                    decrement: { settings.update { $0.minimumFontSize = $0.minimumFontSize <= 6 ? 0 : $0.minimumFontSize - 1 } },
                                    increment: { settings.update { $0.minimumFontSize = $0.minimumFontSize == 0 ? 6 : min(36, $0.minimumFontSize + 1) } },
                                    reset: { settings.update { $0.minimumFontSize = 0 } })
                }
            }
        }
    }

    private var appearanceCaption: String {
        switch settings.value.appearance {
        case .system: "Follows your Mac's light or dark appearance. Applies immediately."
        case .light: "Plinth's bar, panels and settings stay light. Applies immediately."
        case .dark: "Plinth's bar, panels and settings stay dark. Websites that support dark mode follow. Applies immediately."
        }
    }

    private var fadeCaption: String {
        switch settings.value.fadeBehavior {
        case .shorter: "Pages you haven't touched go to the shelf sooner. Applies immediately."
        case .standard: "The default: pages fade to the shelf as they go unused. Applies immediately."
        case .longer: "Pages stay on the bar about twice as long. Applies immediately."
        case .never: "Nothing fades by itself; pages leave the bar only when you put them away. Applies immediately."
        }
    }

    private func swatch(_ choice: AccentChoice) -> some View {
        let c = choice.rgb(dark: t.isDark)
        let color = Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)
        let on = settings.value.accent == choice
        let _ = app.loyaltyModel.revision
        let locked = choice.unlockLevel > app.loyalty.totals.level.number
        return Button { if !locked { settings.update { $0.accent = choice } } } label: {
            Circle().fill(color).frame(width: 20, height: 20)
                .overlay { if locked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) } }
                .opacity(locked ? 0.55 : 1)
                .padding(3)
                .overlay(Circle().strokeBorder(on ? t.p.primary : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? "\(choice.displayName): unlocks at level \(choice.unlockLevel)" : choice.displayName)
        .accessibilityLabel(locked ? "\(choice.displayName), locked until level \(choice.unlockLevel)" : choice.displayName)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}
