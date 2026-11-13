import Foundation
import PlinthModel

/// Decides when a navigation inside a pinned site should open as an ordinary page instead.
///
/// Only a link the user clicked, on a page that is on the pin's own site, leading to another site,
/// is diverted. Everything else stays in the pin, so sign-in flows keep working: server redirects
/// and script navigations are `.other`, form posts are `.formSubmit`, and links that go to a
/// sign-in host or an OAuth-looking path are left alone.
public struct PinLinkPolicy: Sendable {
    let identity: SiteIdentity

    public init(identity: SiteIdentity = SiteIdentity()) { self.identity = identity }

    public func shouldDivert(_ request: NavigationRequest, pinKey: SiteKey) -> Bool {
        guard request.kind == .linkClick else { return false }
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        // Mid sign-in (the pin is currently somewhere else): never interfere.
        if let source = request.sourceURL, identity.key(for: source) != pinKey { return false }
        let target = identity.key(for: request.url)
        guard target != pinKey else { return false }
        return !Self.looksLikeSignIn(request.url)
    }

    static let signInPathMarkers = [
        "/oauth", "/oauth2", "/authorize", "/auth/", "/login", "/signin", "/sign-in", "/sso", "/saml", "/openid",
        "/o/oauth2", "/session", "/logout", "/signout",
    ]

    static func looksLikeSignIn(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        if SiteIdentity.sharedSignInHosts.contains(host) { return true }
        let labels = host.split(separator: ".").map(String.init)
        if let first = labels.first, labels.count >= 3, SiteIdentity.signInPrefixes.contains(first) { return true }
        if SiteIdentity.identityProviderDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        if signInPathMarkers.contains(where: { path.hasPrefix($0) || path.contains($0 + "/") || path == $0 }) { return true }
        let query = (url.query ?? "").lowercased()
        return query.contains("redirect_uri=") || query.contains("client_id=") || query.contains("saml")
    }
}
