import Foundation
import Observation

/// The password manager's own small settings: whether to offer saving, and the sites where the answer is "never".
/// Kept in `passwords.json` beside the other profile files. Holds no secrets.
@MainActor
@Observable
public final class PasswordPreferences {
    public private(set) var offerToSave = true
    public private(set) var neverSave: [WebOrigin] = []
    @ObservationIgnored private let file: URL?

    private struct Stored: Codable {
        var offerToSave: Bool
        var neverSave: [String]
    }

    /// `storageDirectory` nil keeps everything in memory (tests).
    public init(storageDirectory: URL?) {
        file = storageDirectory?.appendingPathComponent("passwords.json")
        guard let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        offerToSave = stored.offerToSave
        neverSave = stored.neverSave.compactMap { WebOrigin(string: $0) }
    }

    public func setOfferToSave(_ on: Bool) { offerToSave = on; persist() }

    public func isNeverSaved(_ origin: WebOrigin) -> Bool { neverSave.contains(origin) }

    public func addNever(_ origin: WebOrigin) {
        guard !neverSave.contains(origin) else { return }
        neverSave.append(origin)
        neverSave.sort { $0.description < $1.description }
        persist()
    }

    public func removeNever(_ origin: WebOrigin) { neverSave.removeAll { $0 == origin }; persist() }

    private func persist() {
        guard let file else { return }
        let stored = Stored(offerToSave: offerToSave, neverSave: neverSave.map(\.description))
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: file, options: .atomic) }
    }
}
