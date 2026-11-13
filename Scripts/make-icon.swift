// Renders Design/icon/*.svg into Scripts/Plinth.icns.
// Usage: swift Scripts/make-icon.swift   (run from the project root)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let full = NSImage(contentsOf: root.appendingPathComponent("Design/icon/plinth-full.svg"))!
let small = NSImage(contentsOf: root.appendingPathComponent("Design/icon/plinth-small.svg"))!
let iconset = root.appendingPathComponent("build/Plinth.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // macOS icons sit inside a margin: the tile takes about 80% of the canvas.
    let inset = CGFloat(pixels) * 0.1
    image.draw(in: NSRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        // The simplified drawing is for 16 and 32 pt, per the brand guide.
        let image = points <= 32 ? small : full
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(image, pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Scripts/Plinth.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Scripts/Plinth.icns" : "iconutil failed")
