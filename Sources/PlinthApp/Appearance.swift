import AppKit
import PlinthSettings

extension AppearanceChoice {
    /// nil follows the Mac.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension NSColor {
    /// Behind pages and empty windows: Stone-tinted cream in light, the Dusk surface in dark.
    static let plinthWindowBackground = NSColor(name: "plinthWindowBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1B / 255, green: 0x1A / 255, blue: 0x2E / 255, alpha: 1)
            : NSColor(srgbRed: 0xFB / 255, green: 0xF8 / 255, blue: 0xF2 / 255, alpha: 1)
    }
}
