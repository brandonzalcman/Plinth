import Foundation
import LocalAuthentication

/// Asks the person at the keyboard to prove it is them (Touch ID, Apple Watch or the Mac's password)
/// before a password is revealed, copied or edited.
public protocol Authenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

public struct DeviceAuthenticator: Authenticating {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // Biometrics, watch or the account password: whichever the Mac offers.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}

/// Test double.
public struct FakeAuthenticator: Authenticating {
    public var allows: Bool
    public init(allows: Bool = true) { self.allows = allows }
    public func authenticate(reason: String) async -> Bool { allows }
}
