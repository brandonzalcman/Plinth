import AppKit
import SwiftUI
import PlinthLoyalty

/// What the share card shows. Only loyalty numbers: nothing about what was browsed.
struct ShareCardContent: Equatable {
    var level: LoyaltyLevel
    var points: Int
    var streak: Int
    var colourway: LoyaltyColourway
}

/// The card people share: the level badge in the user's chosen colourway, the level and points, and the site.
struct ShareCardView: View {
    var content: ShareCardContent
    static let size = CGSize(width: 1200, height: 630)

    var body: some View {
        let way = content.colourway
        let ink = Color(hexString: way.frame)
        ZStack {
            Color(hexString: way.tile)
            HStack(spacing: 72) {
                ZStack {
                    RoundedRectangle(cornerRadius: 96, style: .continuous)
                        .fill(LinearGradient(colors: skyColours(way), startPoint: .top, endPoint: .bottom))
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ZStack {
                            ArchShape().fill(Color(hexString: way.tile))
                            ArchShape().stroke(ink, lineWidth: 14)
                            Text("\(content.level.number)")
                                .font(.system(size: 130, weight: .bold, design: .rounded))
                                .foregroundStyle(ink).offset(y: 40)
                        }
                        .frame(width: 230, height: 260)
                        RoundedRectangle(cornerRadius: 6).fill(ink).frame(width: 300, height: 30)
                        Spacer().frame(height: 56)
                    }
                }
                .frame(width: 420, height: 420)
                VStack(alignment: .leading, spacing: 14) {
                    Text("PLINTH").font(.system(size: 30, weight: .semibold)).tracking(5).foregroundStyle(ink.opacity(0.6))
                    Text(content.level.name).font(.system(size: 104, weight: .bold)).tracking(-4).foregroundStyle(ink)
                    Text("Level \(content.level.number)  ·  \(content.points.formatted()) points")
                        .font(.system(size: 38, weight: .medium)).foregroundStyle(ink.opacity(0.85))
                    if content.streak > 1 {
                        Text("\(content.streak)-day streak").font(.system(size: 30, weight: .medium)).foregroundStyle(ink.opacity(0.65))
                    }
                    Spacer().frame(height: 18)
                    Text("getplinth.dev").font(.system(size: 30, weight: .medium)).foregroundStyle(ink.opacity(0.7))
                }
            }
            .padding(.horizontal, 90)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func skyColours(_ way: LoyaltyColourway) -> [Color] {
        let c = way.sky.map { Color(hexString: $0) }
        return c.count > 1 ? c : [c[0], c[0]]
    }
}

@MainActor enum ShareCard {
    /// The card as a PNG, 2400 by 1260 pixels.
    static func pngData(_ content: ShareCardContent) -> Data? {
        let renderer = ImageRenderer(content: ShareCardView(content: content).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A folder of its own in the temporary directory, one subfolder per share, so two shares never
    /// touch each other's file.
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Plinth Share Cards", isDirectory: true) }

    static func fileURL(for content: ShareCardContent) -> URL? {
        guard let data = pngData(content) else { return nil }
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("Plinth level \(content.level.number).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { return nil }
        return url
    }

    /// Removes share cards older than `age` from the temporary directory (at launch and at quit). A
    /// younger folder may belong to a share in flight, in this or another running Plinth, and a card
    /// copied to the pasteboard stays valid for a while.
    static func removeLeftovers(olderThan age: TimeInterval = 600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in items {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? fm.removeItem(at: url) }
        }
    }
}

/// Opens the system share sheet for the card and counts a completed share. Any completed action of the
/// sheet counts (AirDrop, Messages, Copy, Save...), up to the daily cap. Each share has its own file in
/// its own folder. Nothing is deleted while the share may still be read (a copy leaves a file URL on the
/// pasteboard): folders older than ten minutes are removed at launch and quit. Held by `AppController`,
/// so closing Settings before a share completes does not lose the points.
@MainActor final class ShareCardSharer: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let onShared: () -> Void
    init(onShared: @escaping () -> Void) { self.onShared = onShared }

    func present(_ content: ShareCardContent, from view: NSView) {
        guard let url = ShareCard.fileURL(for: content) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor service: NSSharingService) -> NSSharingServiceDelegate? { self }

    nonisolated func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in self.onShared() }
    }
}

/// A button that remembers its NSView, so the share sheet has something to anchor to.
struct ShareAnchorButton: NSViewRepresentable {
    var title: String
    var action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.fire(_:)))
        b.bezelStyle = .rounded
        b.setAccessibilityLabel(title)
        return b
    }
    func updateNSView(_ b: NSButton, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(_ a: @escaping (NSView) -> Void) { action = a }
        @objc func fire(_ sender: NSButton) { action(sender) }
    }
}
