import Foundation

/// Host classification shared by `SiteIdentity` and `AddressResolver`.
/// A pragmatic stand-in for the public suffix list: compact tables, no network.
enum DomainRules {
    /// Multi-label public suffixes. A registrable domain is one label more than its suffix.
    static let multiLabelSuffixes: Set<String> = {
        var set = Set<String>()
        let byCountry: [String: String] = [
            "uk": "co org ac gov me ltd plc net sch nhs",
            "au": "com net org edu gov id asn",
            "nz": "co net org govt ac school",
            "jp": "co ne or ac go ad ed gr lg",
            "kr": "co or ne go ac re",
            "cn": "com net org gov edu ac",
            "hk": "com org edu gov net",
            "tw": "com org edu gov net idv",
            "sg": "com edu gov org net",
            "in": "co net org gen firm ind ac edu gov res nic",
            "br": "com net org gov edu",
            "mx": "com org gob edu net",
            "ar": "com gob org edu net",
            "co": "com org edu gov net",
            "za": "co org gov ac net web",
            "tr": "com org gov edu net",
            "il": "co org ac gov net muni",
            "ua": "com co org gov edu net",
            "pl": "com net org edu gov",
            "id": "co or ac go web sch my",
            "my": "com org gov edu net",
            "th": "co or ac go in",
            "vn": "com org gov edu net",
            "ph": "com org gov edu net",
            "pk": "com org gov edu net",
            "bd": "com org gov edu net",
            "ng": "com org gov edu net",
            "ke": "co or go ac",
            "eg": "com org gov edu",
            "sa": "com org gov edu net",
            "ae": "co ac gov net org sch",
            "es": "com org gob edu nom",
            "pt": "com org gov edu",
            "fr": "asso gouv",
            "at": "co or ac gv",
            "ru": "com org net msk spb",
            "gr": "com org gov edu net",
            "hu": "co", "ro": "com", "ve": "com", "uy": "com", "ec": "com", "do": "com",
            "gt": "com", "cr": "co", "pa": "com", "py": "com", "bo": "com",
            "pe": "com org gob edu",
            "cl": "gob",
            "ca": "gc on qc bc ab",
            "com": "co uk us eu de",
            "org": "eu js",
            "de": "com",
        ]
        for (tld, seconds) in byCountry {
            for second in seconds.split(separator: " ") { set.insert("\(second).\(tld)") }
        }
        // Hosting platforms where each customer gets a subdomain.
        set.formUnion([
            "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app",
            "herokuapp.com", "web.app", "firebaseapp.com", "appspot.com", "blogspot.com",
            "azurewebsites.net", "cloudfront.net", "glitch.me", "repl.co", "replit.app", "replit.dev",
            "fly.dev", "onrender.com", "surge.sh", "now.sh", "ngrok.io", "ngrok.app", "ngrok-free.app",
            "ngrok-free.dev", "trycloudflare.com", "readthedocs.io", "github.dev", "githubusercontent.com",
            "gitbook.io", "notion.site", "webflow.io", "myshopify.com", "wixsite.com", "carrd.co",
            "bubbleapps.io", "streamlit.app", "hf.space", "deno.dev", "r2.dev", "s3.amazonaws.com",
        ])
        return set
    }()

    /// Top-level names that only exist on a local network. Hosts under them behave like localhost:
    /// plain http by default and the port is part of the site key.
    static let localTLDs: Set<String> = ["localhost", "local", "test", "internal", "lan"]

    /// Plausible TLDs for deciding whether a bare "word.word" is an address.
    /// Deliberately leaves out real TLDs that are far more often file extensions when typed
    /// alone: md, py, sh, so, ps, zip, mov. (Also leaves out bar and pub: "foo.bar".)
    static let commonTLDs: Set<String> = Set("""
        com org net edu gov mil int io co ai app dev me tv fm am info biz xyz online site tech store shop \
        blog cloud page link live news wiki design studio agency digital media social network systems \
        software solutions tools world today life love art club fun games team work works zone space \
        website email group global company center expert guru ninja rocks run pro mobi name jobs travel \
        museum aero coop asia cat tel top vip icu one new google codes guide help how academy school \
        university education institute science health care finance money bank fund capital ventures law \
        legal consulting services support community foundation church charity eco green earth city town \
        place land house homes estate rent cafe restaurant pizza coffee beer wine kitchen food fashion \
        style beauty fit yoga fitness photo photos pics pictures video film movie music audio radio show \
        events tickets game play chat plus build engineering energy auto car cars bike taxi tours flights \
        hotel holiday exchange market markets trade trading llc inc ltd gmbh \
        cc ws to gg ly gl la ms nu sc tk ml ga cf gq pw st su tc vc vg ac ad ae af ag al ao ar as at au ax \
        az ba bb bd be bf bg bh bi bj bm bn bo br bs bt bw by bz ca cd cg ch ci ck cl cm cn cr cu cv cw cx \
        cy cz de dj dk dm do dz ec ee eg es et eu fi fj fk fo fr gd ge gf gh gi gm gp gr gs gt gy hk hm hn \
        hr ht hu id ie il im in iq ir is it je jm jo jp ke kg kh ki kr kw ky kz lb lc li lk lr ls lt lu lv \
        ma mc mg mk mm mn mo mp mq mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nz om pa pe pf pg ph \
        pk pl pm pn pr pt py qa re ro rs ru rw sa sb sd se sg si sj sk sl sm sn sr sv sx sy sz td tf tg th \
        tj tl tm tn tr tt tw tz ua ug uk us uy uz va ve vn vu wf yt za zm zw
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)).subtracting(["py"])

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return false }
            return value <= 255
        }
    }

    /// `host` without brackets.
    static func isIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        guard address.contains(":"), address.count >= 2 else { return false }
        return address.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }
    }

    /// The registrable domain ("example.co.uk" for "shop.example.co.uk"), or nil when the host
    /// has none: a single label, an IP address, or a bare public suffix such as "co.uk".
    static func registrableDomain(of host: String) -> String? {
        guard !isIPv4(host), !host.contains(":") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains("") else { return nil }
        for n in [3, 2] where labels.count >= n {
            if multiLabelSuffixes.contains(labels.suffix(n).joined(separator: ".")) {
                return labels.count == n ? nil : labels.suffix(n + 1).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Decodes one "xn--" label to Unicode; returns the label unchanged when it is not punycode.
    static func unicodeLabel(_ label: String) -> String {
        guard label.lowercased().hasPrefix("xn--") else { return label }
        return decodePunycode(String(label.dropFirst(4))) ?? label
    }

    /// RFC 3492.
    static func decodePunycode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        func adapt(_ deltaIn: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? deltaIn / damp : deltaIn / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        let scalars = Array(input.unicodeScalars)
        guard scalars.allSatisfy(\.isASCII) else { return nil }
        var output: [Unicode.Scalar] = []
        var pos = 0
        if let dash = scalars.lastIndex(of: "-") {
            output = Array(scalars[..<dash])
            pos = dash + 1
        }
        var n = 128, i = 0, bias = 72
        while pos < scalars.count {
            let oldI = i
            var w = 1, k = base
            while true {
                guard pos < scalars.count else { return nil }
                let c = scalars[pos].value
                pos += 1
                let digit: Int
                switch c {
                case 97...122: digit = Int(c) - 97
                case 65...90: digit = Int(c) - 65
                case 48...57: digit = Int(c) - 48 + 26
                default: return nil
                }
                guard w < 1 << 32, i < 1 << 40 else { return nil }
                i += digit * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                w *= base - t
                k += base
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        guard !output.isEmpty else { return nil }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: output)
        return String(result)
    }
}
