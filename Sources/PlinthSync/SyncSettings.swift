import Foundation
import Security

/// The user-facing switch for iCloud sync, and whether this build can sync at all.
///
/// Sync is OFF by default. It can only be turned on in a build signed with a developer team
/// that has an iCloud container entitlement; the ad-hoc signed build has none, so the shell
/// shows "iCloud sync needs a developer team" instead of trying (CloudKit would crash or fail).
public struct SyncSettings {
    public enum Availability: Sendable, Equatable {
        /// The switch is off (the default).
        case off
        /// The switch is on but this build has no iCloud container entitlement.
        case needsDeveloperTeam
        /// On and possible.
        case ready(containerIdentifier: String)
    }

    public static let enabledKey = "PlinthSyncEnabled"
    public static let deviceIDKey = "PlinthSyncDeviceID"
    static let containerEntitlement = "com.apple.developer.icloud-container-identifiers"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Off unless the user turned it on.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var availability: Availability {
        guard isEnabled else { return .off }
        guard let id = Self.cloudKitContainerIdentifier else { return .needsDeveloperTeam }
        return .ready(containerIdentifier: id)
    }

    /// A random ID for this Mac, made once and kept. Not tied to hardware.
    public var deviceID: String {
        if let id = defaults.string(forKey: Self.deviceIDKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.deviceIDKey)
        return id
    }

    /// The Mac's name as shown to other Macs, e.g. "Brandon's MacBook Air".
    public static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// True only when the running app is signed with an iCloud container entitlement.
    public static var isCloudKitConfigured: Bool { cloudKitContainerIdentifier != nil }

    /// The first iCloud container in the app's entitlements, if any.
    public static var cloudKitContainerIdentifier: String? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, containerEntitlement as CFString, nil)
        guard let ids = value as? [String] else { return nil }
        return ids.first { !$0.isEmpty }
        #else
        // iOS has no public SecTask API; the iOS app passes its container explicitly when sync lands there.
        return nil
        #endif
    }

    /// An engine on CloudKit when sync is on and possible, else nil. Constructs no CloudKit
    /// object until the engine first syncs.
    @MainActor
    public func makeCloudKitEngine(stateURL: URL?) -> SyncEngine? {
        guard case .ready(let container) = availability else { return nil }
        return SyncEngine(transport: CloudKitTransport(containerIdentifier: container), deviceID: deviceID,
                          deviceName: Self.deviceName, stateURL: stateURL)
    }
}
