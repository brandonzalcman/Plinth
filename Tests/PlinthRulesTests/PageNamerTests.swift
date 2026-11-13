import Foundation
import Testing
@testable import PlinthRules

@Suite struct PageNamerTests {
    let namer = PageNamer()

    struct Case: Sendable, CustomTestStringConvertible {
        var title: String
        var url: String = "https://www.example.com/"
        var site: String = "Example Air"
        var expected: String
        var testDescription: String { "\"\(title)\" @ \(url) [\(site)]" }
    }

    @Test(arguments: [
        // The contract's example, and its mirror
        Case(title: "Seat map — Example Air · Book flights, hotels and cars", expected: "Seat map"),
        Case(title: "Example Air — Seat map", expected: "Seat map"),
        Case(title: "Seat map | Example Air", expected: "Seat map"),
        Case(title: "Seat map - Example Air", expected: "Seat map"),
        Case(title: "Seat map – Example Air", expected: "Seat map"),
        Case(title: "Seat map · Example Air", expected: "Seat map"),
        Case(title: "Seat map • Example Air", expected: "Seat map"),
        Case(title: "Example Air : Seat map", expected: "Seat map"),
        Case(title: "Example Air :: Seat map", expected: "Seat map"),
        Case(title: "Dashboard » Settings » Example Air", expected: "Dashboard"),
        Case(title: "Example Air « Seat map", expected: "Seat map"),
        Case(title: "Elon Musk (@elonmusk) / X", url: "https://x.com/elonmusk", site: "X", expected: "Elon Musk (@elonmusk)"),
        // Only the site name
        Case(title: "Example Air", expected: "Example Air"),
        Case(title: "example air", expected: "Example Air"),
        Case(title: "Example Air - Official Site", expected: "Example Air"),
        Case(title: "Welcome to Example Air | Official Website", expected: "Example Air"),
        Case(title: "Example Air — Home — ExampleAir.com", url: "https://exampleair.com/", expected: "Home"),
        Case(title: "HackerNews", url: "https://news.ycombinator.com/", site: "Hacker News", expected: "Hacker News"),
        Case(title: "YouTube", url: "https://www.youtube.com/", site: "YouTube", expected: "YouTube"),
        Case(title: "Example: Example", site: "Example", expected: "Example"),
        // Site matching ignores case, diacritics, punctuation; also matches the host
        Case(title: "Café Münster – Speisekarte", site: "Cafe Munster", expected: "Speisekarte"),
        Case(title: "McDonald's | Menu", site: "McDonalds", expected: "Menu"),
        Case(title: "example.com | Pricing", site: "", expected: "Pricing"),
        Case(title: "Pricing | www.example.com", site: "Something Else", expected: "Pricing"),
        Case(title: "Example | Pricing", site: "Something Else", expected: "Pricing"),
        Case(title: "Home | Example Air", expected: "Home"),
        Case(title: "About Example Air | Example Air", expected: "About Example Air"),
        // Notification markers
        Case(title: "(3) Inbox | Example Mail", site: "Example Mail", expected: "Inbox"),
        Case(title: "(99+) Feed | Example Air", expected: "Feed"),
        Case(title: "[2] Messages | Example Air", expected: "Messages"),
        Case(title: "● Draft - Example Air", expected: "Draft"),
        Case(title: "(12) ● Chat • Example Air", expected: "Chat"),
        Case(title: "(2) lofi beats - YouTube", url: "https://www.youtube.com/watch?v=1", site: "YouTube", expected: "lofi beats"),
        Case(title: "(2024) Annual report - Example Air", expected: "(2024) Annual report"),
        Case(title: "Inbox (3) - someone@gmail.com - Gmail", url: "https://mail.google.com/mail/u/0/", site: "Gmail", expected: "Inbox (3)"),
        // Whitespace
        Case(title: "  Pricing \n\t —   Example Air  ", expected: "Pricing"),
        Case(title: "Seat\u{00A0}map\u{200B} — Example Air", expected: "Seat map"),
        // Colons
        Case(title: "Re: budget", expected: "Re: budget"),
        Case(title: "Re: budget - Example Air", expected: "Re: budget"),
        Case(title: "10:30 meeting - Example Air", expected: "10:30 meeting"),
        Case(title: "Swift: a guide | Example Air", expected: "Swift: a guide"),
        Case(title: "Show HN: Foo | Hacker News", url: "https://news.ycombinator.com/item?id=1", site: "Hacker News", expected: "Show HN: Foo"),
        Case(title: "Amazon.com: Kindle Paperwhite", url: "https://www.amazon.com/dp/1", site: "Amazon", expected: "Kindle Paperwhite"),
        Case(title: "Kindle Paperwhite: Amazon", url: "https://www.amazon.com/dp/1", site: "Amazon", expected: "Kindle Paperwhite"),
        Case(title: "GitHub - torvalds/linux: Linux kernel source tree", url: "https://github.com/torvalds/linux", site: "GitHub",
             expected: "torvalds/linux: Linux kernel source tree"),
        Case(title: "The Pragmatic Programmer: Your Journey to Mastery, 20th Anniversary Edition, 2nd Edition",
             site: "Example", expected: "The Pragmatic Programmer"),
        // Things that are not separators
        Case(title: "Yes/No questions - Example Air", expected: "Yes/No questions"),
        Case(title: "Self-driving cars - Wikipedia", url: "https://en.wikipedia.org/wiki/X", site: "Wikipedia", expected: "Self-driving cars"),
        Case(title: "Budget 2026 - Google Sheets", url: "https://docs.google.com/spreadsheets/d/1", site: "Google Sheets", expected: "Budget 2026"),
        Case(title: "Seat map—Example Air", expected: "Seat map—Example Air"),
        // Empty titles
        Case(title: "", url: "https://www.example.com/booking/seat-map.html", expected: "Seat map"),
        Case(title: "   ", url: "https://www.example.com/docs/getting_started/", expected: "Getting started"),
        Case(title: "", url: "https://www.example.com/", expected: "Example Air"),
        Case(title: "", url: "https://www.example.com/index.html", expected: "Example Air"),
        Case(title: "", url: "https://www.example.com/items/123456", expected: "Example Air"),
        Case(title: "", url: "https://www.example.com/d/3f2a9c1e-77aa-4b1e-9c1d-0a1b2c3d4e5f", expected: "Example Air"),
        Case(title: "", url: "https://www.example.com/", site: "", expected: "example.com"),
        Case(title: "", url: "file:///Users/someone/My%20Notes.txt", site: "Files", expected: "My Notes.txt"),
        Case(title: "", url: "about:blank", site: "Blank Page", expected: "Blank Page"),
        Case(title: "", url: "about:blank", site: "", expected: "about:blank"),
        // Nothing meaningful
        Case(title: "—", site: "", expected: "example.com"),
        Case(title: "| - |", expected: "Example Air"),
        Case(title: "(3)", expected: "(3)"),
    ])
    func names(_ c: Case) throws {
        let url = try #require(URL(string: c.url))
        #expect(namer.name(title: c.title, url: url, siteName: c.site) == c.expected)
    }

    @Test func capsAtSixtyCharactersOnAWordBoundary() throws {
        let url = try #require(URL(string: "https://example.com/"))
        let title = "An extraordinarily long headline that keeps going well past what any button could ever show | Example"
        let name = namer.name(title: title, url: url, siteName: "Example")
        #expect(name == "An extraordinarily long headline that keeps going well past…")
        #expect(name.count <= 60)

        let unbroken = String(repeating: "x", count: 200)
        let hard = namer.name(title: unbroken, url: url, siteName: "Example")
        #expect(hard.count == 60)
        #expect(hard.hasSuffix("…"))

        let exactly60 = String(repeating: "ab ", count: 19) + "abc"
        #expect(exactly60.count == 60)
        #expect(namer.name(title: exactly60, url: url, siteName: "Example") == exactly60)
    }

    @Test func neverReturnsAnEmptyString() throws {
        let titles = ["", " ", "\n", "—", "|", "- - -", ":", "()", "(1)", "●", "● ", "…", "\u{200B}", "Example", "Example | Example", ": :", "/"]
        let urls = ["https://example.com/", "about:blank", "file:///", "data:,", "https://example.com/%20", "x:"]
        for title in titles {
            for raw in urls {
                let url = try #require(URL(string: raw))
                for site in ["", "Example", " "] {
                    let name = namer.name(title: title, url: url, siteName: site)
                    #expect(!name.trimmingCharacters(in: .whitespaces).isEmpty, "title \(title.debugDescription) url \(raw) site \(site.debugDescription)")
                    #expect(name.count <= 60)
                }
            }
        }
    }

    @Test func isDeterministic() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let a = namer.name(title: "Seat map — Example Air", url: url, siteName: "Example Air")
        let b = namer.name(title: "Seat map — Example Air", url: url, siteName: "Example Air")
        #expect(a == b)
    }
}

struct PageNamerTaglineCapitalTests {
    private func name(_ title: String, _ host: String = "getplinth.dev", site: String = "Plinth") -> String {
        PageNamer().name(title: title, url: URL(string: "https://\(host)/")!, siteName: site)
    }

    @Test func aLowercaseTaglineAfterTheSiteNameGetsACapital() {
        #expect(name("Plinth — a calm browser for Mac") == "A calm browser for Mac")
    }

    @Test func titlesThatStartWithTheirOwnNameAreLeftAlone() {
        #expect(name("a calm browser for Mac", "example.com", site: "Example") == "a calm browser for Mac")
        #expect(name("Example — iPhone 16 review", "example.com", site: "Example") == "iPhone 16 review")
    }
}
