import Foundation

/// A Chrome extension installed in a Chromium profile, as Plinth shows it in its own extensions menu.
///
/// Chromium's own toolbar is hidden in Plinth, so the shell reads what is installed straight from the
/// profile folder: the `extensions.settings` dictionary in `Secure Preferences` / `Preferences`,
/// and each extension's `manifest.json`.
public struct InstalledExtension: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    /// The toolbar popup page (action.default_popup, or browser_action/page_action in Manifest V2).
    public var popupPath: String?
    /// The best icon file for a small button, if the extension ships one.
    public var iconFile: URL?
    /// The extension's folder on disk.
    public var directory: URL

    /// The popup's address, e.g. chrome-extension://<id>/popup.html.
    public var popupURL: URL? {
        guard let popupPath, !popupPath.isEmpty else { return nil }
        let trimmed = popupPath.hasPrefix("/") ? String(popupPath.dropFirst()) : popupPath
        return URL(string: "chrome-extension://\(id)/\(trimmed)")
    }

    public var optionsURL: URL? { nil }
}

public enum InstalledExtensions {
    /// Chromium's extension locations (extensions::mojom::ManifestLocation) that are part of the
    /// browser itself rather than something the user installed.
    static let builtInLocations: Set<Int> = [5, 10]   // kComponent, kExternalComponent

    /// Every user-visible extension in the profile at `profile`, sorted by name.
    public static func scan(profile: URL, fileManager: FileManager = .default) -> [InstalledExtension] {
        var settings: [String: Any] = [:]
        // Secure Preferences holds the MAC-protected copy; plain Preferences fills any gaps.
        for file in ["Preferences", "Secure Preferences"] {
            guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ext = root["extensions"] as? [String: Any],
                  let entries = ext["settings"] as? [String: Any] else { continue }
            for (id, value) in entries { settings[id] = value }
        }

        var found: [InstalledExtension] = []
        for (id, value) in settings {
            guard let entry = value as? [String: Any] else { continue }
            if let location = entry["location"] as? Int, builtInLocations.contains(location) { continue }
            guard let rawPath = entry["path"] as? String, !rawPath.isEmpty else { continue }
            let directory = rawPath.hasPrefix("/")
                ? URL(fileURLWithPath: rawPath, isDirectory: true)
                : profile.appendingPathComponent("Extensions", isDirectory: true).appendingPathComponent(rawPath, isDirectory: true)
            guard let manifest = Manifest.load(from: directory) else { continue }
            let enabled = isEnabled(entry)
            found.append(InstalledExtension(id: id, name: manifest.name, version: manifest.version, isEnabled: enabled,
                                            popupPath: manifest.popup, iconFile: manifest.icon(in: directory),
                                            directory: directory))
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Chromium records why an extension is off in `disable_reasons` (a bitmask or a list);
    /// older profiles use `state` (1 enabled, 0 disabled).
    static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let reasons = entry["disable_reasons"] as? Int { return reasons == 0 }
        if let reasons = entry["disable_reasons"] as? [Any] { return reasons.isEmpty }
        if let state = entry["state"] as? Int { return state == 1 }
        return true
    }
}

/// The parts of manifest.json Plinth needs, with `__MSG_name__` strings resolved from _locales.
struct Manifest: Equatable {
    var name: String
    var version: String
    var popup: String?
    /// Icon paths keyed by size in pixels.
    var icons: [Int: String]

    static func load(from directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Manifest(json: json, messages: messages(in: directory, defaultLocale: json["default_locale"] as? String))
    }

    init?(json: [String: Any], messages: [String: String] = [:]) {
        guard let rawName = json["name"] as? String else { return nil }
        name = Self.localize(rawName, messages)
        version = json["version"] as? String ?? ""
        var popup: String?
        var icons: [Int: String] = Self.iconMap(json["icons"])
        for key in ["action", "browser_action", "page_action"] {
            guard let action = json[key] as? [String: Any] else { continue }
            if popup == nil, let p = action["default_popup"] as? String, !p.isEmpty { popup = p }
            // A toolbar icon is what the button should show; it wins over the store icon.
            let actionIcons = Self.iconMap(action["default_icon"])
            if !actionIcons.isEmpty { icons = actionIcons }
            break
        }
        self.popup = popup
        self.icons = icons
    }

    /// The icon closest to 32 px, preferring larger over smaller.
    func icon(in directory: URL) -> URL? {
        guard !icons.isEmpty else { return nil }
        let size = icons.keys.filter { $0 >= 32 }.min() ?? icons.keys.max()!
        guard let path = icons[size] else { return nil }
        return directory.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    static func iconMap(_ value: Any?) -> [Int: String] {
        if let single = value as? String { return [16: single] }
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [Int: String] = [:]
        for (k, v) in dict { if let size = Int(k), let path = v as? String { out[size] = path } }
        return out
    }

    static func localize(_ text: String, _ messages: [String: String]) -> String {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__") else { return text }
        let key = String(text.dropFirst(6).dropLast(2)).lowercased()
        return messages[key] ?? text
    }

    /// The default locale's messages, keyed by lowercased message name.
    static func messages(in directory: URL, defaultLocale: String?) -> [String: String] {
        guard let locale = defaultLocale else { return [:] }
        let candidates = [Locale.current.identifier, Locale.current.language.languageCode?.identifier, locale].compactMap { $0 }
        for candidate in candidates {
            let file = directory.appendingPathComponent("_locales/\(candidate)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var out: [String: String] = [:]
            for (k, v) in json { if let m = (v as? [String: Any])?["message"] as? String { out[k.lowercased()] = m } }
            return out
        }
        return [:]
    }
}
