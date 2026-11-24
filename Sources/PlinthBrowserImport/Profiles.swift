import Foundation

/// One profile of a browser: a folder holding its own bookmarks, history and saved logins.
public struct BrowserProfile: Sendable, Equatable {
    /// The folder's own name ("Default", "Profile 2"), or "" when the profile is the browser's data folder itself.
    public var folderName: String
    /// The name the browser shows for it ("Work"), or the folder name when it keeps none.
    public var name: String
    public var folder: URL
}

/// Finds a Chromium-family browser's profiles.
///
/// Most keep each profile in its own folder ("Default", "Profile 1", …) and list them, with the names
/// people gave them, in `Local State`. Opera keeps its main profile in the data folder itself and
/// extra ones under `_side_profiles`. Chromium's internal profiles (system, guest) are left out.
enum ChromiumProfiles {
    static let internalFolders: Set<String> = ["System Profile", "Guest Profile"]
    /// Files that mark a folder as a profile.
    static let markers = ["Bookmarks", "History", "Login Data", "Preferences"]

    static func discover(_ source: ImportSource, home: URL) -> [BrowserProfile] {
        discover(root: source.dataFolder(home: home), rootName: source.displayName)
    }

    static func discover(root: URL, rootName: String) -> [BrowserProfile] {
        let names = localStateNames(root)
        var order: [String] = names.order
        // Folders on disk that Local State doesn't list (or no Local State at all).
        let onDisk = Probe.children(root)
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for folder in ["Default"] + onDisk where !order.contains(folder) { order.append(folder) }

        var out: [BrowserProfile] = []
        // Opera: the data folder is the main profile.
        if isProfile(root) { out.append(BrowserProfile(folderName: "", name: rootName, folder: root)) }
        for folder in order where !internalFolders.contains(folder) {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            guard isProfile(url) else { continue }
            out.append(BrowserProfile(folderName: folder, name: names.byFolder[folder] ?? folder, folder: url))
        }
        let side = root.appendingPathComponent("_side_profiles", isDirectory: true)
        for folder in Probe.children(side).sorted() {
            let url = side.appendingPathComponent(folder, isDirectory: true)
            if isProfile(url) { out.append(BrowserProfile(folderName: "_side_profiles/" + folder, name: folder, folder: url)) }
        }
        return out
    }

    static func isProfile(_ folder: URL) -> Bool {
        markers.contains { Probe.state(folder.appendingPathComponent($0)) != .missing }
    }

    /// Profile names and order from `Local State` (`profile.info_cache` and `profile.profiles_order`).
    static func localStateNames(_ root: URL) -> (order: [String], byFolder: [String: String]) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = json["profile"] as? [String: Any] else { return ([], [:]) }
        var byFolder: [String: String] = [:]
        for case let (folder, info as [String: Any]) in (profile["info_cache"] as? [String: Any]) ?? [:] {
            if let name = info["name"] as? String, !name.isEmpty { byFolder[folder] = name }
        }
        var order = (profile["profiles_order"] as? [String]) ?? []
        for folder in byFolder.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !order.contains(folder) {
            order.append(folder)
        }
        return (order, byFolder)
    }
}

/// Finds a Firefox-family browser's profiles from `profiles.ini`.
enum FirefoxProfiles {
    /// Profile folders, the one the browser last used first: the install's default, then those marked
    /// `Default=1`, then the rest, then any folder under `Profiles` the file doesn't list.
    static func candidates(root: URL) -> [URL] {
        var paths: [URL] = []
        func add(_ url: URL) { if !paths.contains(url) { paths.append(url) } }
        if let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            let parsed = parse(text)
            for entry in parsed.installDefaults + parsed.marked + parsed.all { add(resolve(entry, root: root)) }
        }
        let profilesDir = root.appendingPathComponent("Profiles", isDirectory: true)
        for name in Probe.children(profilesDir).sorted() { add(profilesDir.appendingPathComponent(name, isDirectory: true)) }
        return paths
    }

    /// The profile the browser last used that has `places.sqlite`.
    static func primary(root: URL) -> URL? {
        candidates(root: root).first { Probe.state($0.appendingPathComponent("places.sqlite")) != .missing }
    }

    struct Entry: Equatable {
        var path: String
        var isRelative: Bool
    }

    static func resolve(_ entry: Entry, root: URL) -> URL {
        entry.isRelative ? root.appendingPathComponent(entry.path, isDirectory: true) : URL(fileURLWithPath: entry.path, isDirectory: true)
    }

    static func parse(_ text: String) -> (installDefaults: [Entry], marked: [Entry], all: [Entry]) {
        var section = ""
        var path: String?
        var isRelative = true
        var isDefault = false
        var installDefaults: [Entry] = []
        var marked: [Entry] = []
        var all: [Entry] = []
        func flush() {
            guard section.hasPrefix("Profile"), let path else { return }
            let entry = Entry(path: path, isRelative: isRelative)
            all.append(entry)
            if isDefault { marked.append(entry) }
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                section = String(line.dropFirst().dropLast())
                path = nil; isRelative = true; isDefault = false
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            // Install sections name their default profile by a relative path.
            if section.hasPrefix("Install"), key == "Default" { installDefaults.append(Entry(path: value, isRelative: true)) }
            if section.hasPrefix("Profile") {
                if key == "Path" { path = value }
                if key == "IsRelative" { isRelative = value != "0" }
                if key == "Default", value == "1" { isDefault = true }
            }
        }
        flush()
        return (installDefaults, marked, all)
    }
}
