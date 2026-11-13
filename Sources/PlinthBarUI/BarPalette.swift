import SwiftUI
import AppKit
import PlinthModel

extension Color {
    /// 0xRRGGBB in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Every colour the bar uses, resolved once from the colour scheme.
/// Light follows Design/brand-guide.md ("Bottom bar styling", Sunrise palette).
/// Dark is derived from the Dusk colourway: surfaces #1B1A2E, text #F4EEE6.
struct BarPalette {
    var isDark: Bool
    var bar: Color
    var barBorder: Color
    var shadow: Color
    var divider: Color
    /// Site capsule fill.
    var capsule: Color
    /// Page names that are not current, glyphs, the search button's text.
    var text: Color
    /// A fading page inside a live capsule.
    var textFaded: Color
    /// Dashed outline of anything fading.
    var dashed: Color
    /// Icon tint of a fading site. Never used for text.
    var fadingIcon: Color
    var searchFill: Color
    var searchBorder: Color
    /// Laid behind a button under the pointer (Haze at low opacity).
    var hover: Color
    /// A page lit up as the target of a drag-to-split (Haze, stronger than hover).
    var dropTarget: Color
    /// The close button's disc on a page that is not current.
    var closeFill: Color
    var badgeFill: Color
    /// Pinned tile without a favicon, and its letter.
    var pinTile: Color
    var pinLetter: Color
    /// Pinned tile behind a favicon, and its hairline.
    var pinIconTile: Color
    var pinIconBorder: Color
    /// Text on the accent.
    var onAccent: Color

    static let light = BarPalette(
        isDark: false,
        bar: Color(hex: 0xFFFFFF),
        barBorder: Color(hex: 0xE3DCCB),            // Sand
        shadow: Color(hex: 0x1C1C1A, opacity: 0.14), // Ink
        divider: Color(hex: 0xE3DCCB),              // Sand
        capsule: Color(hex: 0xF6F1E7),              // Stone
        text: Color(hex: 0x4A4A45),
        textFaded: Color(hex: 0x6F6A60),
        dashed: Color(hex: 0xC9B9A0),
        fadingIcon: Color(hex: 0xFFC9A3),           // Dawn
        searchFill: Color(hex: 0xFBF8F2),
        searchBorder: Color(hex: 0xE3DCCB),         // Sand
        hover: Color(hex: 0x93AAFF, opacity: 0.22), // Haze
        dropTarget: Color(hex: 0x93AAFF, opacity: 0.5), // Haze
        closeFill: Color(hex: 0xE9E2D3),
        badgeFill: Color(hex: 0xE9E2D3),
        pinTile: Color(hex: 0x1C1C1A),              // Ink
        pinLetter: Color(hex: 0xF6F1E7),            // Stone
        pinIconTile: Color(hex: 0xF6F1E7),          // Stone
        pinIconBorder: Color(hex: 0xE3DCCB),        // Sand
        onAccent: .white
    )

    static let dark = BarPalette(
        isDark: true,
        bar: Color(hex: 0x1B1A2E),                  // Dusk tile
        barBorder: Color(hex: 0x3A3860),
        shadow: Color.black.opacity(0.5),
        divider: Color(hex: 0x3A3860),
        capsule: Color(hex: 0x2A2945),
        text: Color(hex: 0xCBC6D6),
        textFaded: Color(hex: 0xA29DB3),
        dashed: Color(hex: 0x7D6E88),
        fadingIcon: Color(hex: 0xFFC9A3, opacity: 0.8), // Dawn
        searchFill: Color(hex: 0x232238),
        searchBorder: Color(hex: 0x413F68),
        hover: Color(hex: 0x93AAFF, opacity: 0.16), // Haze
        dropTarget: Color(hex: 0x93AAFF, opacity: 0.34), // Haze
        closeFill: Color(hex: 0x423F69),
        badgeFill: Color(hex: 0x423F69),
        pinTile: Color(hex: 0xF4EEE6),              // Dusk frame
        pinLetter: Color(hex: 0x1B1A2E),
        pinIconTile: Color(hex: 0x2A2945),
        pinIconBorder: Color(hex: 0x413F68),
        onAccent: .white
    )

    static func resolve(_ scheme: ColorScheme) -> BarPalette { scheme == .dark ? .dark : .light }

    /// The accent as used for thin lines (pin ring, split bracket). Sky is too dim
    /// as a hairline on the Dusk surface, so it is lifted towards Haze there.
    func accentLine(_ accent: Color) -> Color { isDark ? accent.mix(with: .white, by: 0.38) : accent }
}

/// A stable colour per site, used for the 16 pt icon square until a favicon arrives.
/// (Pinned tiles do not use it: they are Ink with a Stone letter.)
enum SiteTint {
    /// All dark enough for white text.
    static let swatches: [UInt32] = [
        0xC2532D, 0x1F7A5C, 0x6A4BD0, 0x2F5BEA, 0xB8405E, 0x0E7C86,
        0x9A6400, 0x4B6B2A, 0x8A3FA0, 0x3D5A80, 0xB5382C, 0x5B5F97,
    ]

    /// FNV-1a over the host, so the colour is the same on every launch (unlike `Hasher`).
    static func index(for key: SiteKey) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.host.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(swatches.count))
    }

    static func color(for key: SiteKey) -> Color { Color(hex: swatches[index(for: key)]) }
}
