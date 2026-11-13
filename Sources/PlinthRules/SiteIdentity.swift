import Foundation
import PlinthModel

/// Decides what counts as one website, and what to call it when the page gives no better hint.
///
/// Key rules, in order:
/// 1. Anything that is not http(s) is keyed by its scheme ("file", "about", "data").
/// 2. The host is lowercased; a trailing dot is dropped.
/// 3. localhost, IP addresses, single-label hosts and hosts under .local/.test/.internal/.lan
///    keep a non-default port in the key ("localhost:3000", "[::1]:3000"). Nothing else is merged for them.
/// 4. Leading `www.`, `m.`, `mobile.`, `amp.` are stripped (repeatedly) while what remains still
///    contains a registrable domain. Wikimedia's inner "m" label (en.m.wikipedia.org) is dropped too.
/// 5. A sign-in prefix (`login.`, `auth.`, `signin.`, `sso.`, `accounts.` ...) folds into its parent
///    only when the parent is exactly the registrable domain and the host is not a known shared
///    sign-in host (accounts.google.com, login.microsoftonline.com ...) or an identity provider.
/// 6. A handful of exact aliases (youtu.be -> youtube.com, twitter.com -> x.com, old.reddit.com -> reddit.com).
/// Real subdomains otherwise stay distinct. The port of an ordinary domain is ignored.
public struct SiteIdentity: SiteIdentifying {
    public init() {}

    public func key(for url: URL) -> SiteKey {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            if scheme.isEmpty {
                let text = url.absoluteString
                if !text.isEmpty, !text.hasPrefix("/"), let retry = URL(string: "https://" + text),
                   let host = retry.host, !host.isEmpty {
                    return key(for: retry)
                }
                return SiteKey("unknown")
            }
            return SiteKey(scheme)
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return SiteKey(scheme) }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix("."), host.count > 1 { host.removeLast() }

        var labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let isIPv6 = DomainRules.isIPv6(host)
        let isLocal = isIPv6 || DomainRules.isIPv4(host) || labels.count == 1
            || DomainRules.localTLDs.contains(labels[labels.count - 1])
        if isLocal {
            var key = isIPv6 ? "[\(host)]" : host
            if let port = url.port, port != (scheme == "https" ? 443 : 80) { key += ":\(port)" }
            return SiteKey(key)
        }

        // 4. Presentation prefixes.
        while labels.count >= 3, Self.strippedPrefixes.contains(labels[0]),
              DomainRules.registrableDomain(of: labels.dropFirst().joined(separator: ".")) != nil {
            labels.removeFirst()
        }
        host = labels.joined(separator: ".")
        if let registrable = DomainRules.registrableDomain(of: host), Self.wikimediaDomains.contains(registrable) {
            let keep = registrable.split(separator: ".").count
            let sub = labels.dropLast(keep).filter { $0 != "m" }
            labels = sub + labels.suffix(keep)
            host = labels.joined(separator: ".")
        }

        // 5. Sign-in hosts.
        if labels.count >= 3, Self.signInPrefixes.contains(labels[0]),
           !Self.sharedSignInHosts.contains(host),
           let registrable = DomainRules.registrableDomain(of: host),
           registrable == labels.dropFirst().joined(separator: "."),
           !Self.identityProviderDomains.contains(registrable) {
            host = registrable
        }

        // 6. Aliases.
        return SiteKey(Self.aliases[host] ?? host)
    }

    public func siteName(for key: SiteKey) -> String {
        let host = key.host
        if let known = Self.knownNames[host] { return known }
        guard host.contains("."), !host.contains(":"), !DomainRules.isIPv4(host) else {
            // Schemes, localhost, single-label hosts, IPs and anything with a port.
            return Self.schemeNames[host] ?? (host.isEmpty ? "Page" : host)
        }
        let labels = host.split(separator: ".").map(String.init)
        guard let last = labels.last, !DomainRules.localTLDs.contains(last) else { return host }
        let registrable = DomainRules.registrableDomain(of: host) ?? host
        let registrableLabels = registrable.split(separator: ".").map(String.init)
        let base = Self.knownNames[registrable] ?? Self.prettify(registrableLabels[0])
        let sub = labels.dropLast(registrableLabels.count).reversed().map(Self.prettify)
        let name = ([base] + sub).filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? host : name
    }

    // MARK: - Tables

    static let strippedPrefixes: Set<String> = ["www", "m", "mobile", "amp"]

    static let signInPrefixes: Set<String> = [
        "login", "signin", "sign-in", "auth", "sso", "oauth", "oauth2", "logon",
        "accounts", "account", "identity", "idp", "signup",
    ]

    /// Sign-in hosts that serve several distinct sites, or that are an app in their own right.
    /// These keep their own key.
    static let sharedSignInHosts: Set<String> = [
        "accounts.google.com", "accounts.youtube.com", "login.microsoftonline.com", "login.live.com",
        "login.microsoft.com", "account.microsoft.com", "account.apple.com", "login.yahoo.com",
        "login.aol.com", "auth.atlassian.com", "login.salesforce.com", "accounts.firefox.com",
        "auth.openai.com", "accounts.spotify.com", "accounts.zoho.com", "account.proton.me",
        "sso.godaddy.com", "accounts.shopify.com", "login.ubuntu.com", "login.docker.com",
        "accounts.autodesk.com", "account.samsung.com", "login.wikimedia.org", "accounts.snapchat.com",
        "auth.riotgames.com", "accounts.nintendo.com", "login.tailscale.com", "account.adobe.com",
        "accounts.epicgames.com", "login.steampowered.com", "account.amazon.com",
    ]

    /// Registrable domains whose whole purpose is signing in to other sites.
    static let identityProviderDomains: Set<String> = [
        "okta.com", "oktapreview.com", "auth0.com", "onelogin.com", "microsoftonline.com",
        "duosecurity.com", "pingidentity.com", "pingone.com", "b2clogin.com", "windows.net",
        "cloudflareaccess.com", "jumpcloud.com",
    ]

    static let wikimediaDomains: Set<String> = [
        "wikipedia.org", "wiktionary.org", "wikimedia.org", "wikiquote.org", "wikibooks.org",
        "wikisource.org", "wikinews.org", "wikiversity.org", "wikivoyage.org", "wikidata.org", "mediawiki.org",
    ]

    static let aliases: [String: String] = [
        "youtu.be": "youtube.com",
        "twitter.com": "x.com",
        "old.reddit.com": "reddit.com", "new.reddit.com": "reddit.com", "np.reddit.com": "reddit.com",
        "fb.com": "facebook.com", "web.facebook.com": "facebook.com",
        "mbasic.facebook.com": "facebook.com", "touch.facebook.com": "facebook.com",
        "smile.amazon.com": "amazon.com",
        "gmail.com": "mail.google.com", "googlemail.com": "mail.google.com",
    ]

    static let schemeNames: [String: String] = [
        "file": "Files", "about": "Blank Page", "data": "Data", "blob": "Blob",
        "mailto": "Mail", "unknown": "Page",
    ]

    static let knownNames: [String: String] = [
        "google.com": "Google", "mail.google.com": "Gmail", "docs.google.com": "Google Docs",
        "drive.google.com": "Google Drive", "calendar.google.com": "Google Calendar",
        "maps.google.com": "Google Maps", "meet.google.com": "Google Meet",
        "photos.google.com": "Google Photos", "accounts.google.com": "Google Account",
        "translate.google.com": "Google Translate", "news.google.com": "Google News",
        "youtube.com": "YouTube", "music.youtube.com": "YouTube Music",
        "github.com": "GitHub", "gist.github.com": "GitHub Gist", "gitlab.com": "GitLab",
        "news.ycombinator.com": "Hacker News", "ycombinator.com": "Y Combinator",
        "stackoverflow.com": "Stack Overflow", "stackexchange.com": "Stack Exchange",
        "wikipedia.org": "Wikipedia", "en.wikipedia.org": "Wikipedia",
        "x.com": "X", "facebook.com": "Facebook", "instagram.com": "Instagram",
        "linkedin.com": "LinkedIn", "reddit.com": "Reddit", "tiktok.com": "TikTok",
        "whatsapp.com": "WhatsApp", "web.whatsapp.com": "WhatsApp",
        "amazon.com": "Amazon", "ebay.com": "eBay", "netflix.com": "Netflix",
        "open.spotify.com": "Spotify", "spotify.com": "Spotify", "twitch.tv": "Twitch",
        "apple.com": "Apple", "icloud.com": "iCloud", "developer.apple.com": "Apple Developer",
        "microsoft.com": "Microsoft", "outlook.live.com": "Outlook", "outlook.office.com": "Outlook",
        "login.microsoftonline.com": "Microsoft Sign-in", "office.com": "Microsoft 365",
        "chatgpt.com": "ChatGPT", "openai.com": "OpenAI", "claude.ai": "Claude",
        "anthropic.com": "Anthropic", "notion.so": "Notion", "figma.com": "Figma",
        "slack.com": "Slack", "app.slack.com": "Slack", "discord.com": "Discord",
        "zoom.us": "Zoom", "dropbox.com": "Dropbox", "paypal.com": "PayPal",
        "nytimes.com": "The New York Times", "theguardian.com": "The Guardian",
        "bbc.com": "BBC", "bbc.co.uk": "BBC", "cnn.com": "CNN", "imdb.com": "IMDb",
        "duckduckgo.com": "DuckDuckGo", "linear.app": "Linear", "vercel.com": "Vercel",
        "npmjs.com": "npm", "developer.mozilla.org": "MDN", "medium.com": "Medium",
        "substack.com": "Substack", "airbnb.com": "Airbnb", "booking.com": "Booking.com",
    ]

    static let acronyms: [String: String] = [
        "api": "API", "ai": "AI", "id": "ID", "tv": "TV", "uk": "UK", "us": "US", "eu": "EU",
        "faq": "FAQ", "cdn": "CDN", "ui": "UI",
    ]

    /// "my-site" -> "My Site", "xn--bcher-kva" -> "Bücher".
    static func prettify(_ label: String) -> String {
        DomainRules.unicodeLabel(label)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { word -> String in
                let word = String(word)
                if let acronym = acronyms[word.lowercased()] { return acronym }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
