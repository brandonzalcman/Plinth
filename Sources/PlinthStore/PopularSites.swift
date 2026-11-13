import Foundation
import PlinthModel

/// Well-known sites the address bar can offer straight away ("github" -> github.com), whether or
/// not they are in the history. Matching is by prefix of the name, the domain's first label or an
/// alias, so a few letters are enough.
enum PopularSites {
    struct Site: Sendable {
        var name: String
        var domain: String
        var aliases: [String] = []
    }

    static let all: [Site] = [
        Site(name: "Google", domain: "google.com"),
        Site(name: "YouTube", domain: "youtube.com", aliases: ["yt"]),
        Site(name: "Gmail", domain: "mail.google.com", aliases: ["mail", "email"]),
        Site(name: "Google Drive", domain: "drive.google.com", aliases: ["gdrive"]),
        Site(name: "Google Docs", domain: "docs.google.com", aliases: ["gdocs"]),
        Site(name: "Google Maps", domain: "maps.google.com", aliases: ["gmaps"]),
        Site(name: "Google Calendar", domain: "calendar.google.com", aliases: ["gcal"]),
        Site(name: "Google Translate", domain: "translate.google.com"),
        Site(name: "GitHub", domain: "github.com", aliases: ["gh"]),
        Site(name: "GitLab", domain: "gitlab.com"),
        Site(name: "Bitbucket", domain: "bitbucket.org"),
        Site(name: "Stack Overflow", domain: "stackoverflow.com", aliases: ["so"]),
        Site(name: "npm", domain: "npmjs.com"),
        Site(name: "Hacker News", domain: "news.ycombinator.com", aliases: ["hn", "ycombinator"]),
        Site(name: "Reddit", domain: "reddit.com"),
        Site(name: "X", domain: "x.com", aliases: ["twitter"]),
        Site(name: "Facebook", domain: "facebook.com", aliases: ["fb"]),
        Site(name: "Instagram", domain: "instagram.com", aliases: ["ig", "insta"]),
        Site(name: "LinkedIn", domain: "linkedin.com"),
        Site(name: "Threads", domain: "threads.net"),
        Site(name: "TikTok", domain: "tiktok.com"),
        Site(name: "Pinterest", domain: "pinterest.com"),
        Site(name: "Snapchat", domain: "snapchat.com"),
        Site(name: "WhatsApp", domain: "web.whatsapp.com", aliases: ["whatsapp"]),
        Site(name: "Discord", domain: "discord.com"),
        Site(name: "Slack", domain: "slack.com"),
        Site(name: "Telegram", domain: "web.telegram.org", aliases: ["telegram"]),
        Site(name: "Twitch", domain: "twitch.tv"),
        Site(name: "Netflix", domain: "netflix.com"),
        Site(name: "Disney+", domain: "disneyplus.com", aliases: ["disney"]),
        Site(name: "Prime Video", domain: "primevideo.com"),
        Site(name: "Hulu", domain: "hulu.com"),
        Site(name: "Max", domain: "max.com", aliases: ["hbo"]),
        Site(name: "Spotify", domain: "open.spotify.com", aliases: ["spotify"]),
        Site(name: "SoundCloud", domain: "soundcloud.com"),
        Site(name: "Apple", domain: "apple.com"),
        Site(name: "iCloud", domain: "icloud.com"),
        Site(name: "Apple Developer", domain: "developer.apple.com", aliases: ["appledev"]),
        Site(name: "App Store Connect", domain: "appstoreconnect.apple.com", aliases: ["appstoreconnect"]),
        Site(name: "Microsoft", domain: "microsoft.com"),
        Site(name: "Outlook", domain: "outlook.com"),
        Site(name: "Office", domain: "office.com"),
        Site(name: "OneDrive", domain: "onedrive.live.com"),
        Site(name: "Teams", domain: "teams.microsoft.com"),
        Site(name: "Zoom", domain: "zoom.us"),
        Site(name: "Google Meet", domain: "meet.google.com"),
        Site(name: "Notion", domain: "notion.so"),
        Site(name: "Figma", domain: "figma.com"),
        Site(name: "Canva", domain: "canva.com"),
        Site(name: "Linear", domain: "linear.app"),
        Site(name: "Asana", domain: "asana.com"),
        Site(name: "Trello", domain: "trello.com"),
        Site(name: "Jira", domain: "atlassian.com"),
        Site(name: "Dropbox", domain: "dropbox.com"),
        Site(name: "Box", domain: "box.com"),
        Site(name: "Amazon", domain: "amazon.com"),
        Site(name: "eBay", domain: "ebay.com"),
        Site(name: "Etsy", domain: "etsy.com"),
        Site(name: "Walmart", domain: "walmart.com"),
        Site(name: "Target", domain: "target.com"),
        Site(name: "Best Buy", domain: "bestbuy.com"),
        Site(name: "AliExpress", domain: "aliexpress.com"),
        Site(name: "Shopify", domain: "shopify.com"),
        Site(name: "PayPal", domain: "paypal.com"),
        Site(name: "Stripe", domain: "stripe.com", aliases: ["dashboard.stripe"]),
        Site(name: "Venmo", domain: "venmo.com"),
        Site(name: "Wise", domain: "wise.com"),
        Site(name: "Coinbase", domain: "coinbase.com"),
        Site(name: "Robinhood", domain: "robinhood.com"),
        Site(name: "Wikipedia", domain: "wikipedia.org", aliases: ["wiki"]),
        Site(name: "IMDb", domain: "imdb.com"),
        Site(name: "Medium", domain: "medium.com"),
        Site(name: "Substack", domain: "substack.com"),
        Site(name: "The New York Times", domain: "nytimes.com", aliases: ["nyt"]),
        Site(name: "BBC", domain: "bbc.com"),
        Site(name: "CNN", domain: "cnn.com"),
        Site(name: "The Guardian", domain: "theguardian.com", aliases: ["guardian"]),
        Site(name: "Bloomberg", domain: "bloomberg.com"),
        Site(name: "The Verge", domain: "theverge.com", aliases: ["verge"]),
        Site(name: "ChatGPT", domain: "chatgpt.com", aliases: ["gpt", "openai"]),
        Site(name: "Claude", domain: "claude.ai", aliases: ["anthropic"]),
        Site(name: "Gemini", domain: "gemini.google.com"),
        Site(name: "Perplexity", domain: "perplexity.ai"),
        Site(name: "Hugging Face", domain: "huggingface.co", aliases: ["hf"]),
        Site(name: "Vercel", domain: "vercel.com"),
        Site(name: "Netlify", domain: "netlify.com"),
        Site(name: "Cloudflare", domain: "cloudflare.com"),
        Site(name: "AWS", domain: "aws.amazon.com", aliases: ["aws"]),
        Site(name: "Google Cloud", domain: "console.cloud.google.com", aliases: ["gcp"]),
        Site(name: "Supabase", domain: "supabase.com"),
        Site(name: "Firebase", domain: "firebase.google.com"),
        Site(name: "Docker Hub", domain: "hub.docker.com", aliases: ["docker"]),
        Site(name: "MDN Web Docs", domain: "developer.mozilla.org", aliases: ["mdn"]),
        Site(name: "Swift", domain: "swift.org"),
        Site(name: "Codepen", domain: "codepen.io"),
        Site(name: "Dribbble", domain: "dribbble.com"),
        Site(name: "Behance", domain: "behance.net"),
        Site(name: "Unsplash", domain: "unsplash.com"),
        Site(name: "Duolingo", domain: "duolingo.com"),
        Site(name: "Coursera", domain: "coursera.org"),
        Site(name: "Khan Academy", domain: "khanacademy.org", aliases: ["khan"]),
        Site(name: "Airbnb", domain: "airbnb.com"),
        Site(name: "Booking.com", domain: "booking.com", aliases: ["booking"]),
        Site(name: "Uber", domain: "uber.com"),
        Site(name: "DoorDash", domain: "doordash.com"),
        Site(name: "Yelp", domain: "yelp.com"),
        Site(name: "Craigslist", domain: "craigslist.org"),
        Site(name: "Zillow", domain: "zillow.com"),
        Site(name: "Weather", domain: "weather.com"),
        Site(name: "Speedtest", domain: "speedtest.net"),
        Site(name: "DuckDuckGo", domain: "duckduckgo.com", aliases: ["ddg"]),
        Site(name: "Bing", domain: "bing.com"),
        Site(name: "Brave", domain: "brave.com"),
        Site(name: "Plinth", domain: "getplinth.dev"),
    ]

    /// Sites whose name, domain label or alias starts with `token` (already folded), best first:
    /// an exact alias or name, then the order of the table (which lists the most used first).
    static func matches(_ token: String) -> [Site] {
        guard token.count >= 2 else { return [] }
        var exact: [Site] = []
        var prefix: [Site] = []
        for site in all {
            let name = site.name.lowercased()
            // Only an apex domain's label counts ("github" for github.com, not "docs" for docs.google.com).
            let parts = site.domain.split(separator: ".")
            let label = parts.count == 2 ? String(parts[0]) : ""
            let aliases = site.aliases
            if name == token || label == token || aliases.contains(token) { exact.append(site) }
            else if name.hasPrefix(token) || label.hasPrefix(token) || (token.count >= 3 && aliases.contains { $0.hasPrefix(token) }) { prefix.append(site) }
        }
        return exact + prefix
    }

    static func result(for site: Site) -> SearchResult {
        let url = URL(string: "https://\(site.domain)/")!
        var result = SearchResult(id: "site-" + site.domain, target: .history(url), title: site.name,
                                  subtitle: site.domain, key: SiteKey(site.domain))
        result.isTopHit = true
        return result
    }
}
