import Foundation
import PlinthModel

extension BrowserStore {
    /// The folders among the pins, in bar order, each with its pins.
    public var pinFolders: [(folder: PinFolder, pins: [PinnedSite])] {
        var out: [(folder: PinFolder, pins: [PinnedSite])] = []
        for pin in BarOrder.arranged(pins) {
            guard let f = pin.folder else { continue }
            if let i = out.firstIndex(where: { $0.folder.id == f.id }) { out[i].pins.append(pin) } else { out.append((f, [pin])) }
        }
        return out
    }

    /// Puts the pin in a new folder of its own. The name defaults to "Folder", then "Folder 2"...
    @discardableResult
    public func createPinFolder(with pin: SiteID, name: String? = nil) -> PinFolder? {
        guard let pi = pins.firstIndex(where: { $0.id == pin }) else { return nil }
        let folder = PinFolder(name: uniqueFolderName(clean(name) ?? PinFolder.defaultName))
        pins[pi].folder = folder
        commit()
        return folder
    }

    /// Moves the pin into an existing folder, after its last member. Does nothing for an unknown folder.
    public func movePin(_ pin: SiteID, toFolder folderID: UUID) {
        guard let pi = pins.firstIndex(where: { $0.id == pin }),
              let folder = pins.compactMap(\.folder).first(where: { $0.id == folderID }),
              pins[pi].folder?.id != folderID else { return }
        var moved = pins.remove(at: pi)
        moved.folder = folder
        let at = pins.lastIndex { $0.folder?.id == folderID }.map { $0 + 1 } ?? pins.count
        pins.insert(moved, at: at)
        pruneAndTidyPinFolders()
        commit()
    }

    /// Takes the pin out of its folder; it sits just after the folder on the bar.
    public func removePinFromFolder(_ pin: SiteID) {
        guard let pi = pins.firstIndex(where: { $0.id == pin }), let fid = pins[pi].folder?.id else { return }
        var moved = pins.remove(at: pi)
        moved.folder = nil
        let at = (pins.lastIndex { $0.folder?.id == fid }.map { $0 + 1 }) ?? min(pi, pins.count)
        pins.insert(moved, at: at)
        pruneAndTidyPinFolders()
        commit()
    }

    /// Blank names are ignored.
    public func renamePinFolder(_ id: UUID, to name: String) {
        guard let name = clean(name), pins.contains(where: { $0.folder?.id == id }) else { return }
        for i in pins.indices where pins[i].folder?.id == id { pins[i].folder?.name = name }
        commit()
    }

    /// The folder goes away; its pins stay where they are on the bar.
    public func ungroupPinFolder(_ id: UUID) {
        guard pins.contains(where: { $0.folder?.id == id }) else { return }
        for i in pins.indices where pins[i].folder?.id == id { pins[i].folder = nil }
        commit()
    }

    /// Repairs folder state: one name per folder, members together, no blank names. Folders of one
    /// member are kept (they are how a folder is started). Returns whether anything changed.
    @discardableResult
    func pruneAndTidyPinFolders() -> Bool {
        var names: [UUID: String] = [:]
        var tidy = pins
        for i in tidy.indices {
            guard var f = tidy[i].folder else { continue }
            if let known = names[f.id] { f.name = known } else {
                f.name = clean(f.name) ?? PinFolder.defaultName
                names[f.id] = f.name
            }
            tidy[i].folder = f
        }
        tidy = BarOrder.arranged(tidy)
        guard tidy != pins else { return false }
        pins = tidy
        return true
    }

    private func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(40))
    }

    private func uniqueFolderName(_ base: String) -> String {
        let existing = Set(pins.compactMap { $0.folder?.name })
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
