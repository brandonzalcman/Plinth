import AppKit
import SwiftUI
import PlinthLoyalty

/// Draws the Plinth icon in a brand colourway (docs/brand-guide.md, "Icon source": a 280 by 280 grid).
enum AppIconRenderer {
    private static func ns(_ hex: String) -> NSColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// The tile alone, filling the image. With `dockMargin` the tile sits inside the margin macOS
    /// icons have (about 10% a side).
    static func image(_ way: LoyaltyColourway, size: CGFloat, dockMargin: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let inset = dockMargin ? rect.width * 0.1 : 0
            let box = rect.insetBy(dx: inset, dy: inset)
            let k = box.width / 280
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * k, y: box.minY + y * k) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: box.minX + x * k, y: box.minY + y * k, width: w * k, height: h * k) }

            let tile = NSBezierPath(roundedRect: r(0.5, 0.5, 279, 279), xRadius: 64 * k, yRadius: 64 * k)
            ns(way.tile).setFill(); tile.fill()
            let lightTile = way.id == "sunrise" || way.id == "meadow" || way.id == "ember" || way.id == "mono"
            // Light tiles carry a border a shade darker than the tile; dark ones a faint light edge.
            (lightTile ? ns("#D9D0BC") : NSColor(white: 1, alpha: 0.16)).setStroke()
            tile.lineWidth = k; tile.stroke()

            // The arch: 92..188 wide, flat bottom at 192, round top of radius 48.
            let arch = NSBezierPath()
            arch.move(to: p(92, 192)); arch.line(to: p(92, 108))
            arch.appendArc(withCenter: p(140, 108), radius: 48 * k, startAngle: 180, endAngle: 0, clockwise: false)
            arch.line(to: p(188, 192)); arch.close()

            NSGraphicsContext.saveGraphicsState()
            arch.addClip()
            let colours = way.sky.count > 1 ? way.sky.map(ns) : [ns(way.sky[0]), ns(way.sky[0])]
            let locations: [CGFloat] = colours.count == 3 ? [0, 0.6, 1] : [0, 1]
            // The view is flipped: the gradient angle 90 runs top to bottom.
            NSGradient(colors: colours, atLocations: locations, colorSpace: .sRGB)?.draw(in: r(92, 60, 96, 132), angle: 90)
            ns(way.sun).setFill()
            NSBezierPath(ovalIn: r(114, 160, 52, 52)).fill()
            NSGraphicsContext.restoreGraphicsState()

            let frame = NSBezierPath()
            frame.move(to: p(92, 192)); frame.line(to: p(92, 108))
            frame.appendArc(withCenter: p(140, 108), radius: 48 * k, startAngle: 180, endAngle: 0, clockwise: false)
            frame.line(to: p(188, 192))
            frame.lineWidth = 10 * k; frame.lineJoinStyle = .round
            ns(way.frame).setStroke(); frame.stroke()

            ns(way.frame).setFill()
            NSBezierPath(roundedRect: r(72, 190, 136, 20), xRadius: 4 * k, yRadius: 4 * k).fill()
            NSBezierPath(roundedRect: r(50, 214, 180, 20), xRadius: 4 * k, yRadius: 4 * k).fill()
            return true
        }
    }
}

extension AppController {
    /// The Dock icon follows the setting while Plinth runs. The Finder icon is part of the signed app
    /// and cannot change; the Dock icon reverts to it when Plinth quits, and is set again at launch.
    func applyAppIcon() {
        let id = settings.value.appIcon
        guard let way = LoyaltyColourway.named(id), id != LoyaltyColourway.sunrise.id, loyalty.isUnlocked(way) else {
            NSApp.applicationIconImage = nil
            return
        }
        NSApp.applicationIconImage = AppIconRenderer.image(way, size: 512, dockMargin: true)
    }
}

/// The icon picker in Settings.
struct AppIconPicker: View {
    let app: AppController
    @Environment(\.settingsTheme) private var t

    var body: some View {
        let _ = app.loyaltyModel.revision
        let level = app.loyalty.totals.level.number
        // A saved icon the level no longer unlocks is not shown as selected: Sunrise is in use.
        let chosen = LoyaltyColourway.named(app.settings.value.appIcon).flatMap { $0.unlockLevel <= level ? $0 : nil } ?? .sunrise
        HStack(spacing: 14) {
            ForEach(LoyaltyColourway.all) { way in
                let locked = way.unlockLevel > level
                let on = chosen.id == way.id
                Button {
                    if !locked { app.settings.update { $0.appIcon = way.id } }
                } label: {
                    VStack(spacing: 6) {
                        Image(nsImage: AppIconRenderer.image(way, size: 56))
                            .resizable().frame(width: 56, height: 56)
                            .opacity(locked ? 0.4 : 1)
                            .overlay { if locked { Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(t.p.primary) } }
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(on ? t.accent : .clear, lineWidth: 2.5))
                        Text(way.name).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(locked ? t.p.tertiary : t.p.primary)
                        Text(locked ? "Level \(way.unlockLevel)" : " ").font(.system(size: 10)).foregroundStyle(t.p.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .help(locked ? "\(way.name) unlocks at level \(way.unlockLevel)" : way.name)
                .accessibilityLabel(locked ? "\(way.name) icon, locked until level \(way.unlockLevel)" : "\(way.name) icon")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
