import AppKit
import SwiftUI
import Observation
import PlinthModel
import PlinthSync
import PlinthSettings
import PlinthLoyalty

/// Lets SwiftUI views refresh when the loyalty ledgers change.
@MainActor @Observable final class LoyaltyModel {
    private(set) var revision = 0
    func bump() { revision += 1 }
}

extension Color {
    init(hexString: String) {
        let v = UInt32(hexString.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension AccentChoice {
    /// The level that unlocks this accent: the colourway accents unlock with their level, the rest are free.
    var unlockLevel: Int { LoyaltyColourway.named(rawValue)?.unlockLevel ?? 1 }
}

extension AppController {
    // MARK: Setup

    /// A launch with `PLINTH_STORAGE` is a scratch profile: it never syncs loyalty and never uses the
    /// real device ID, so a scripted run cannot write points to the real account.
    var isScratchProfile: Bool { ProcessInfo.processInfo.environment["PLINTH_STORAGE"] != nil }

    func setUpLoyalty() {
        let file = storageDirectory.appendingPathComponent("loyalty.json")
        let firstRun = !FileManager.default.fileExists(atPath: file.path)
        let engine = LoyaltyEngine(deviceID: isScratchProfile ? "scratch-profile" : SyncSettings().deviceID, platform: .mac, fileURL: file)
        loyalty = engine
        // The first run of the loyalty system credits what already exists (pins, bookmarks, a day of
        // use) without a level-up card, even when sync turns on a moment later.
        if firstRun { silentUntil = Date().addingTimeInterval(60) }
        engine.onChange = { [weak self] in
            guard let self else { return }
            self.loyaltyModel.bump()
            self.announceLevelUpIfPossible()
            self.pushLoyaltyToSync()
        }
        earnDayOfUse()
        loyaltyTick()
    }

    /// Records an event. A level-up shows the quiet level-up moment (see `announceLevelUpIfPossible`).
    func earn(_ event: LoyaltyEvent) { loyalty.record(event) }

    /// One use per day, not from a private window. Called at launch, on activation and every few seconds
    /// while Plinth is active, so a day is not missed if Plinth stays frontmost across midnight.
    func earnDayOfUse() {
        guard loyalty != nil, !(keyWindowID.map { store.isPrivate(window: $0) } ?? false) else { return }
        earn(.dayOfUse)
    }

    /// Called every few seconds: credits one-off milestones for things the user has done. Private
    /// windows do not count.
    func loyaltyTick() {
        guard loyalty.isEnabled else { return }
        earnDayOfUse()
        if !store.pins.isEmpty { earn(.milestone(.firstPin)) }
        if !bookmarks.bookmarks.isEmpty { earn(.milestone(.firstBookmark)) }
        if store.windows.contains(where: { !$0.isPrivate && $0.split != nil }) { earn(.milestone(.firstSplitView)) }
        if sync != nil { earn(.milestone(.syncOn)) }
    }

    /// Shows the level-up card only when Plinth is the active app and the welcome guide is not up.
    /// Otherwise the level stays unannounced and is shown at the next change that finds it possible.
    /// Levels reached during the first minute of the first run are acknowledged silently.
    private func announceLevelUpIfPossible() {
        if let until = silentUntil, Date() < until { _ = loyalty.claimLevelUp(); return }
        guard NSApp.isActive, welcome?.window?.isVisible != true else { return }
        if let level = loyalty.claimLevelUp() { LoyaltyToast.show(level: level) }
    }

    // MARK: Sync

    func connectLoyalty(to coordinator: SyncCoordinator) {
        guard !isScratchProfile else { return }
        coordinator.engine.ownLoyaltyLedger = loyalty.ownLedgerData
    }

    func ingestLoyaltyFromSync() {
        guard !isScratchProfile, let engine = sync?.engine else { return }
        loyalty.ingest(engine.loyaltyLedgers())
    }

    private func pushLoyaltyToSync() {
        guard !isScratchProfile, let coordinator = sync else { return }
        coordinator.engine.ownLoyaltyLedger = loyalty.ownLedgerData
        coordinator.scheduleSync(local: { self.store.syncPayload() }, openPages: { self.store.openPagesSummary() },
                                 apply: { self.store.applySynced($0) })
    }
}

// MARK: - Badge

/// The level badge: the arch from the logo with the level number, in the colourway's colours.
struct LoyaltyBadge: View {
    var level: LoyaltyLevel
    var colourway: LoyaltyColourway = .sunrise
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(Color(hexString: colourway.tile))
            ArchShape()
                .fill(LinearGradient(colors: colourway.sky.map { Color(hexString: $0) }.count > 1
                                     ? colourway.sky.map { Color(hexString: $0) } : [Color(hexString: colourway.sky[0]), Color(hexString: colourway.sky[0])],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(ArchShape().stroke(Color(hexString: colourway.frame), lineWidth: size * 0.04))
                .frame(width: size * 0.5, height: size * 0.52)
                .offset(y: -size * 0.04)
            Text("\(level.number)").font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hexString: colourway.id == "mono" ? "#FFFFFF" : colourway.frame))
                .offset(y: size * 0.1)
            VStack { Spacer(); RoundedRectangle(cornerRadius: size * 0.02).fill(Color(hexString: colourway.frame)).frame(width: size * 0.62, height: size * 0.07) }
                .padding(.bottom, size * 0.12)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("Level \(level.number), \(level.name)")
    }
}

struct ArchShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Level-up moment

/// A small card near the bottom of the screen that fades in, stays a few seconds and fades out.
/// Reduce Motion: it appears and disappears without sliding.
@MainActor enum LoyaltyToast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(level: LoyaltyLevel) {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        let unlock = LoyaltyColourway.all.first { $0.unlockLevel == level.number }
        let host = NSHostingView(rootView: LevelUpCard(level: level, unlock: unlock))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.ignoresMouseEvents = true
        p.contentView = host
        if let screen = (NSApp.keyWindow?.screen ?? NSScreen.main) {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - host.frame.width / 2, y: f.minY + 110))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()   // only called while Plinth is the active app (see announceLevelUpIfPossible)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
        panel = p
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
    }
}

private struct LevelUpCard: View {
    var level: LoyaltyLevel
    var unlock: LoyaltyColourway?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = PanelPaletteBridge(scheme)
        HStack(spacing: 14) {
            LoyaltyBadge(level: level, colourway: unlock ?? .sunrise, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Level \(level.number): \(level.name)").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.primary)
                Text(unlock.map { "\($0.name) app icon and accent unlocked" } ?? "Keep going")
                    .font(.system(size: 12)).foregroundStyle(p.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.surface)
            .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .padding(24)
    }
}

/// Just the few colours the card needs.
private struct PanelPaletteBridge {
    var surface: Color, border: Color, primary: Color, secondary: Color
    init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        surface = dark ? Color(hexString: "#1B1A2E") : .white
        border = dark ? Color.white.opacity(0.14) : Color(hexString: "#E3DCCB")
        primary = dark ? Color(hexString: "#F4EEE6") : Color(hexString: "#1C1C1A")
        secondary = dark ? Color(hexString: "#F4EEE6").opacity(0.7) : Color(hexString: "#4A4A45")
    }
}
