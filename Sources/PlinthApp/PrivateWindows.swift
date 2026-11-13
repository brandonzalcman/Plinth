import AppKit
import SwiftUI
import WebKit
import PlinthModel

// Private windows at the app level: one non-persistent data store per window, shared by that window's
// pages (and its peek and popups) and nothing else, released when the window closes. What the
// store keeps out of history, the shelf and saved state is in PlinthStore/Private.swift.

/// Midnight, from docs/brand-guide.md: the dark alternate colourway, used for the private window.
enum PrivateTint {
    static let surface = NSColor(srgbRed: 0x0E / 255, green: 0x12 / 255, blue: 0x20 / 255, alpha: 1)
    static let text = Color(red: 0xE9 / 255, green: 0xEC / 255, blue: 0xF5 / 255)
    /// Light blue from the Midnight row, for the badge and its ring.
    static let highlight = Color(red: 0x8F / 255, green: 0xD3 / 255, blue: 0xFF / 255)
    /// Multiplied over the bar so it reads as Midnight rather than the usual dark surface.
    static let barTint = Color(red: 0.74, green: 0.82, blue: 1.0)
}

extension AppController {
    func newPrivateWindow() {
        showControllerPublic(for: store.createPrivateWindow())
    }

    @objc func menuNewPrivateWindow(_ sender: Any?) { newPrivateWindow() }

    /// The store for a private window's pages; nil for a normal window.
    func privateDataStore(for window: WindowID) -> WKWebsiteDataStore? {
        guard store.isPrivate(window: window) else { return nil }
        if let existing = privateStores[window] { return existing }
        let made = WKWebsiteDataStore.nonPersistent()
        privateStores[window] = made
        return made
    }

    func dataStore(forPage id: PageID) -> WKWebsiteDataStore? {
        store.windowID(containing: id).flatMap { privateDataStore(for: $0) }
    }

    /// The window is gone: its popups close, its downloads leave the tray (the files stay), and the
    /// store, with every cookie and site record in it, is dropped.
    func privateWindowClosed(_ id: WindowID) {
        guard let dataStore = privateStores.removeValue(forKey: id) else { return }
        for popup in popups where popup.uses(dataStore) { popup.window.close() }
        pool.forgetDownloads(of: dataStore)
        // Belt and braces: the store is in memory only, but empty it before the last view lets go.
        Task { @MainActor in
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}

/// "Private" next to the traffic lights.
struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .semibold))
            Text("Private").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(PrivateTint.highlight)
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(Capsule().fill(Color(nsColor: PrivateTint.surface).opacity(0.92)))
        .overlay(Capsule().strokeBorder(PrivateTint.highlight.opacity(0.45), lineWidth: 1))
        .fixedSize()
    }
}
