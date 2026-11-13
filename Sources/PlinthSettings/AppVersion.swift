import Foundation

/// The app's version and build number, read from the bundle's Info.plist.
/// An unbundled run (`swift run`) has neither key, so it reads as a development build.
public struct AppVersion: Equatable, Sendable {
    /// `CFBundleShortVersionString`, e.g. "0.1.2"; nil when the bundle has none.
    public var version: String?
    /// `CFBundleVersion`, e.g. "3"; nil when the bundle has none.
    public var build: String?

    public init(version: String?, build: String?) {
        self.version = Self.clean(version)
        self.build = Self.clean(build)
    }

    public init(infoDictionary info: [String: Any]?) {
        self.init(version: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String)
    }

    /// The running app's version.
    public static var current: AppVersion { AppVersion(infoDictionary: Bundle.main.infoDictionary) }

    /// "Version 0.1.2 (3)", "Version 0.1.2", or "Development build".
    public var displayString: String {
        guard let version else { return build.map { "Development build (\($0))" } ?? "Development build" }
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    /// Empty strings and unfilled Xcode placeholders like "$(MARKETING_VERSION)" count as missing.
    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
