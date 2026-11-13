import SwiftUI
import AppKit
import PlinthModel

/// A site's favicon, or its initial on an Ink square with a Stone letter (swapped in dark mode,
/// where Ink would vanish into the surface).
/// Decorative by default: rows that use it carry the label.
public struct SiteIconView: View {
    private let key: SiteKey
    private let name: String
    private let image: NSImage?
    private let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    public init(key: SiteKey, name: String, image: NSImage?, size: CGFloat = 16) {
        self.key = key; self.name = name; self.image = image; self.size = size
    }

    public var body: some View {
        let palette = PanelPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                shape.fill(palette.iconFill)
                    .overlay(
                        Text(Self.letter(name: name, key: key))
                            .font(.system(size: max(8, size * 0.6), weight: .semibold))
                            .foregroundStyle(palette.iconLetter)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    /// The first letter or digit of the name, falling back to the host.
    public static func letter(name: String, key: SiteKey) -> String {
        for source in [name, key.host] {
            if let c = source.first(where: { $0.isLetter || $0.isNumber }) { return String(c).uppercased() }
        }
        return "•"
    }
}
