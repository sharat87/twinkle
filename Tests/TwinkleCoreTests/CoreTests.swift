import Foundation
import Testing
@testable import TwinkleCore

let ddg = "https://duckduckgo.com/?q=%s"

@Suite struct AddressTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("example.com/path?q=1", "https://example.com/path?q=1"),
        ("https://example.com/a", "https://example.com/a"),
        ("http://example.com", "http://example.com"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost", "http://localhost"),
        ("192.168.1.10/admin", "http://192.168.1.10/admin"),
        ("myserver:8080", "http://myserver:8080"),
        ("printer.local", "http://printer.local"),
        ("about:blank", "about:blank"),
        ("  github.com  ", "https://github.com"),
    ])
    func addresses(input: String, expected: String) {
        #expect(Address.resolve(input, searchTemplate: ddg)?.absoluteString == expected)
    }

    @Test(arguments: ["hello world", "swift", "what is 2+2?", "foo.bar baz", "1.5"])
    func searches(input: String) {
        let url = Address.resolve(input, searchTemplate: ddg)
        #expect(url?.host() == "duckduckgo.com")
    }

    @Test func searchEncoding() {
        let url = Address.resolve("a&b c", searchTemplate: ddg)
        #expect(url?.absoluteString == "https://duckduckgo.com/?q=a%26b%20c")
    }

    @Test func samePage() {
        let u = { (s: String) in URL(string: s)! }
        #expect(Address.samePage(u("https://example.com"), u("https://example.com/")))
        #expect(Address.samePage(u("HTTPS://Example.com/a?b=1"), u("https://example.com/a?b=1")))
        #expect(!Address.samePage(u("https://example.com/a"), u("https://example.com/A")))
        #expect(!Address.samePage(u("https://example.com/"), u("http://example.com/")))
        #expect(!Address.samePage(u("https://example.com/#x"), u("https://example.com/")))
        #expect(!Address.samePage(u("https://example.com/?a=1"), u("https://example.com/")))
    }

    @Test func httpsUpgrade() {
        let up = { (s: String) in Address.httpsUpgrade(URL(string: s)!)?.absoluteString }
        #expect(up("http://example.com/a?b=1#c") == "https://example.com/a?b=1#c")
        #expect(up("HTTP://Example.com") == "https://Example.com")
        #expect(up("https://example.com/") == nil)
        #expect(up("http://example.com:8080/") == nil)
        #expect(up("http://localhost/") == nil)
        #expect(up("http://192.168.1.1/") == nil)
        #expect(up("http://[::1]/") == nil)
        #expect(up("http://nas/") == nil)
        #expect(up("http://printer.local/") == nil)
        #expect(up("about:blank") == nil)
    }
}

@Suite struct WindowTitleTests {
    @Test func titleAndHost() {
        let title = WindowTitle.make(title: "Sign in", url: URL(string: "https://accounts.example.com/login"))
        #expect(title == "Sign in (accounts.example.com)")
    }

    @Test func noPageTitleUsesHost() {
        let title = WindowTitle.make(title: " ", url: URL(string: "https://example.com"))
        #expect(title == "example.com (example.com)")
    }

    @Test func blankTab() {
        #expect(WindowTitle.make(title: "", url: nil) == "Twinkle")
        #expect(WindowTitle.make(title: "  About  ", url: URL(string: "about:blank")) == "About")
    }
}

@Suite struct SettingsTests {
    @Test func partialFileKeepsDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"historyDays": 30}"#.utf8))
        #expect(s.historyDays == 30)
        #expect(s.searchURL == Settings().searchURL)
    }

    @Test func ignoresRemovedSettingsKeys() throws {
        let json = #"{"windowTitleFormat": "{title}", "adBlocking": false, "adBlockingOffFor": ["example.com"], "historyDays": 90}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.historyDays == 90)
        #expect(s.searchURL == Settings().searchURL)
    }

    @Test func containersLiveInTheSameFile() throws {
        let json = ##"{"historyDays": 30, "containers": [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work"}]}"##
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(json.utf8))
        #expect(file.settings.historyDays == 30)
        #expect(file.containers?.map(\.name) == ["Work"])

        let missing = try JSONDecoder().decode(SettingsFile.self, from: Data(#"{"historyDays": 30}"#.utf8))
        #expect(missing.containers == nil)

        let again = try JSONDecoder().decode(SettingsFile.self, from: JSONEncoder().encode(file))
        #expect(again == file)
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        #expect(keys["containers"] != nil && keys["searchURL"] != nil)
        #expect((keys["containers"] as? [String: [String: Any]])?["Work"]?["name"] == nil)
    }

    @Test func nameKeyedContainersDecodeAndEncode() throws {
        let json = ##"{"containers":{"Work":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","color":"#F97316","appleScriptEnabled":true},"Personal":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE"}}}"##
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(json.utf8))
        #expect(file.containers?.map(\.name) == ["Personal", "Work"])
        #expect(file.containers?.first?.color == ContainerList.palette[0])
        #expect(file.containers?.last?.appleScriptEnabled == true)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        let containers = encoded["containers"] as! [String: [String: Any]]
        #expect(containers["Work"]?["name"] == nil)
        #expect(containers["Work"]?["appleScriptEnabled"] as? Bool == true)
        #expect(containers["Personal"] != nil)
    }
}

@Suite struct FilterConverterTests {
    func rules(_ text: String) -> [ContentRule] { FilterConverter.convert(text).rules }

    /// WebKit's url-filter is a subset of ICU regex and case-insensitive by
    /// default, so NSRegularExpression is a faithful stand-in.
    func matches(_ filter: String, _ url: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: filter, options: [.caseInsensitive])
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test func domainAnchor() throws {
        let r = try #require(rules("||ads.example.com^").first)
        #expect(r.action == .block)
        let f = r.trigger.urlFilter
        #expect(matches(f, "https://ads.example.com/banner.js"))
        #expect(matches(f, "https://cdn.ads.example.com/x"))
        #expect(matches(f, "http://ads.example.com/"))
        #expect(matches(f, "https://ads.example.com:8443/"))
        #expect(!matches(f, "https://ads.example.community/"))
        #expect(!matches(f, "https://notads.example.com/"))
        #expect(!matches(f, "https://example.org/?u=ads.example.com.evil"))
    }

    @Test func domainAnchorIsOneRule() {
        #expect(rules("||ads.example.com^").count == 1)
        #expect(rules("||ads.example.com/path^").count == 2)
    }

    @Test func trailingSeparatorAlsoMatchesEndOfURL() {
        let filters = rules("/ads.js^").map(\.trigger.urlFilter)
        #expect(filters.count == 2)
        #expect(filters.contains { matches($0, "https://x.com/ads.js?v=1") })
        #expect(filters.contains { matches($0, "https://x.com/ads.js") })
        #expect(!filters.contains { matches($0, "https://x.com/ads.json") })
    }

    @Test func pathsAndWildcards() throws {
        let f = try #require(rules("/banner/*/ad.gif").first).trigger.urlFilter
        #expect(matches(f, "https://x.com/banner/123/ad.gif"))
        #expect(!matches(f, "https://x.com/banner/ad.png"))
        let start = try #require(rules("|https://tracker.").first).trigger.urlFilter
        #expect(matches(start, "https://tracker.io/p"))
        #expect(!matches(start, "https://site.com/?r=https://tracker.io"))
    }

    @Test func options() throws {
        let r = try #require(rules("||cdn.example^$third-party,script,domain=a.com|b.org").first)
        #expect(r.trigger.loadType == ["third-party"])
        #expect(r.trigger.resourceType == ["script"])
        #expect(r.trigger.ifDomain == ["*a.com", "*b.org"])
    }

    @Test func negatedTypes() throws {
        let r = try #require(rules("||x.com^$~script,~image").first)
        let types = try #require(r.trigger.resourceType)
        #expect(!types.contains("script") && !types.contains("image") && types.contains("style-sheet"))
    }

    @Test func subdocumentIsChildFrameOnly() throws {
        let r = try #require(rules("||ads.net^$subdocument").first)
        #expect(r.trigger.resourceType == ["document"])
        #expect(r.trigger.loadContext == ["child-frame"])
    }

    @Test func unsupportedOptionsAreSkipped() {
        let result = FilterConverter.convert("||x.com^$redirect=noop.js\n||y.com^$csp=script-src 'none'\n/ads[0-9]+/")
        #expect(result.rules.isEmpty)
        #expect(result.skipped == 3)
    }

    @Test func matchEverythingNeedsADomain() {
        #expect(rules("*").isEmpty)
        #expect(rules("*$script,domain=example.com").count == 1)
    }

    @Test func elementHiding() throws {
        let all = rules("##.ad-banner\n##.sponsored\nnews.com,blog.news.com##.popup\n~safe.com##.annoying")
        let generic = try #require(all.first { $0.trigger.ifDomain == nil && $0.trigger.unlessDomain == nil })
        #expect(generic.action == .hide(".ad-banner, .sponsored"))
        let scoped = try #require(all.first { $0.trigger.ifDomain != nil })
        #expect(scoped.trigger.ifDomain == ["*blog.news.com", "*news.com"])
        let unless = try #require(all.first { $0.trigger.unlessDomain != nil })
        #expect(unless.trigger.unlessDomain == ["*safe.com"])
    }

    @Test func proceduralCosmeticsAreSkipped() {
        let result = FilterConverter.convert("##div:has-text(Sponsored)\nexample.com##+js(nobab)\nexample.com#@#.ad\nexample.com#?#.x:-abp-has(.y)")
        #expect(result.rules.isEmpty)
        #expect(result.skipped == 4)
    }

    @Test func exceptionsComeAfterBlocksAndPageExceptionsLast() {
        let all = rules("@@||good.com^$document\n##.ad\n@@||cdn.com/ok.js\n||cdn.com^")
        #expect(all.map(\.action.type) == ["block", "ignore-previous-rules", "css-display-none", "ignore-previous-rules"])
        #expect(all.last?.trigger.ifDomain == ["*good.com"])
    }

    @Test func hostsFiles() {
        let all = rules("# comment\n127.0.0.1 localhost\n0.0.0.0 tracker.example.net # inline\n0.0.0.0 0.0.0.0")
        #expect(all.count == 1)
        #expect(matches(all[0].trigger.urlFilter, "https://tracker.example.net/pixel"))
    }

    @Test func encodesWebKitKeys() throws {
        let json = String(decoding: try JSONEncoder().encode(rules("||a.com^$third-party")), as: UTF8.self)
        #expect(json.contains(#""url-filter""#))
        #expect(json.contains(#""load-type":["third-party"]"#))
        #expect(!json.contains("if-domain"))
    }

    @Test func builtinListConverts() {
        let result = FilterConverter.convert(BuiltinFilters.text)
        #expect(result.skipped == 0)
        #expect(result.rules.count > 30)
    }
}

@Suite struct ContainerSiteTests {
    let personal = Container(name: "Personal", color: "#3B82F6")
    let work = Container(name: "Work", color: "#F97316")
    var containers: [Container] { [personal, work] }

    @Test func subdomainsAndMostSpecificWins() {
        let domains = Domains([
            "example.com": DomainSettings(container: "Personal"),
            "mail.example.com": DomainSettings(container: "Work"),
            "corp.io": DomainSettings(container: "work"),
        ])
        #expect(domains.assignment(forHost: "example.com", in: containers)?.container.name == "Personal")
        #expect(domains.assignment(forHost: "www.example.com", in: containers)?.container.name == "Personal")
        #expect(domains.assignment(forHost: "mail.example.com", in: containers)?.container.name == "Work")
        #expect(domains.assignment(forHost: "a.mail.example.com", in: containers)?.container.name == "Work")
        #expect(domains.assignment(forHost: "WWW.CORP.IO.", in: containers)?.container.name == "Work")
        #expect(domains.assignment(forHost: "notexample.com", in: containers) == nil)
        #expect(domains.assignment(forHost: nil, in: containers) == nil)
    }

    @Test func assignMovesTheSiteAndSupportsWildcard() {
        var domains = Domains([
            "example.com": DomainSettings(container: "Personal"),
            "mail.example.com": DomainSettings(container: "Work"),
            "corp.io": DomainSettings(container: "Work"),
        ])
        #expect(domains.setContainer("Personal", forHost: "www.corp.io") == "corp.io")
        #expect(domains.entries["corp.io"]?.container == "Personal")
        #expect(domains.assignment(forHost: "corp.io", in: containers)?.container.name == "Personal")

        // Clearing removes the entry when there is no inherited default.
        #expect(domains.setContainer(nil, forHost: "corp.io") == "corp.io")
        #expect(domains.entries["corp.io"] == nil)
        #expect(domains.assignment(forHost: "corp.io", in: containers) == nil)

        // Assigning a subdomain preserves its parent's container, and clearing it overrides to none.
        domains.setContainer("Work", forHost: "docs.example.com")
        #expect(domains.assignment(forHost: "docs.example.com", in: containers)?.container.name == "Work")
        #expect(domains.assignment(forHost: "example.com", in: containers)?.container.name == "Personal")
        domains.setContainer(nil, forHost: "docs.example.com")
        #expect(domains.entries["docs.example.com"]?.container == "")
        #expect(domains.assignment(forHost: "docs.example.com", in: containers) == nil)
        domains.setContainer("Personal", forHost: "docs.example.com")
        #expect(domains.entries["docs.example.com"] == nil)

        // Wildcard container default.
        var withDefault = Domains(["*": DomainSettings(container: "Personal")])
        #expect(withDefault.assignment(forHost: "any.example", in: containers)?.container.name == "Personal")
        withDefault.setContainer(nil, forHost: "plain.example")
        #expect(withDefault.assignment(forHost: "plain.example", in: containers) == nil)
        withDefault.setContainer("Personal", forHost: "plain.example")
        #expect(withDefault.entries["plain.example"] == nil)
    }

    @Test func containerDefaultsAndIgnoresLegacySitesKey() throws {
        let json = ##"{"containers":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","color":"#22C55E","sites":["example.com"]}]}"##
        let l = try JSONDecoder().decode(ContainerList.self, from: Data(json.utf8))
        #expect(l.containers[0].name == "Old")
        #expect(!l.containers[0].appleScriptEnabled)
    }
}

@Suite struct ZoomTests {
    @Test func steps() {
        #expect(Zoom.step(from: 1, in: true) == 1.1)
        #expect(Zoom.step(from: 1, in: false) == 0.9)
        #expect(Zoom.step(from: 1.2, in: true) == 1.25)
        #expect(Zoom.step(from: 3, in: true) == 3)
        #expect(Zoom.step(from: 0.5, in: false) == 0.5)
    }

    @Test func perDomain() throws {
        var d = Domains()
        #expect(d.setZoom(1.25, forHost: "www.example.com") == "example.com")
        #expect(d.zoom(forHost: "example.com") == 1.25)
        #expect(d.zoom(forHost: "docs.example.com") == 1.25)
        #expect(d.zoom(forHost: "other.com") == 1)
        d.setZoom(1.5, forHost: "docs.example.com")
        #expect(d.entries == ["example.com": DomainSettings(zoom: 1.5)])
        d.setZoom(1, forHost: "example.com")
        #expect(d.entries.isEmpty)

        // An entry without a zoom doesn't hide a broader one's.
        d.entries = ["example.com": DomainSettings(zoom: 0.8), "docs.example.com": DomainSettings()]
        #expect(d.zoom(forHost: "docs.example.com") == 0.8)

        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(#"{"domains": {"a.com": {"zoom": 0.8}}}"#.utf8))
        #expect(file.domains.zoom(forHost: "a.com") == 0.8)
        let none = try JSONDecoder().decode(SettingsFile.self, from: Data("{}".utf8))
        #expect(none.domains.entries.isEmpty)
    }

    @Test func wildcardZoomDefaultAndOverride() {
        var d = Domains([Domains.wildcard: DomainSettings(zoom: 1.25)])
        #expect(d.zoom(forHost: nil) == 1.25)
        #expect(d.zoom(forHost: "") == 1.25)
        #expect(d.zoom(forHost: "example.com") == 1.25)

        // Overriding "*" back to 1.0 stores an entry for the domain and leaves "*" intact.
        #expect(d.setZoom(1.0, forHost: "www.example.com") == "example.com")
        #expect(d.zoom(forHost: "example.com") == 1.0)
        #expect(d.zoom(forHost: "sub.example.com") == 1.0)
        #expect(d.zoom(forHost: "other.com") == 1.25)
        #expect(d.entries["*"] == DomainSettings(zoom: 1.25))
        #expect(d.entries["example.com"] == DomainSettings(zoom: 1.0))

        // Setting back to the wildcard default removes the domain override.
        #expect(d.setZoom(1.25, forHost: "sub.example.com") == "example.com")
        #expect(d.entries == ["*": DomainSettings(zoom: 1.25)])
    }

    @Test func adBlockingPerDomainAndWildcard() {
        var d = Domains()
        #expect(d.blocks(on: nil))
        #expect(d.blocks(on: "www.example.com"))
        #expect(d.setAdBlockingOff(true, forHost: "www.example.com") == "example.com")
        #expect(!d.blocks(on: "www.example.com"))
        #expect(!d.blocks(on: "example.com"))
        #expect(d.blocks(on: "notexample.com"))
        #expect(d.setAdBlockingOff(false, forHost: "sub.example.com") == "example.com")
        #expect(d.entries.isEmpty)

        // Wildcard adBlockingOff: true with domain override false and toggling back.
        d = Domains(["*": DomainSettings(adBlockingOff: true)])
        #expect(!d.blocks(on: nil))
        #expect(!d.blocks(on: "example.com"))
        #expect(d.setAdBlockingOff(false, forHost: "www.example.com") == "example.com")
        #expect(d.blocks(on: "www.example.com"))
        #expect(d.blocks(on: "sub.example.com"))
        #expect(!d.blocks(on: "other.com"))
        #expect(d.entries["*"] == DomainSettings(adBlockingOff: true))
        #expect(d.entries["example.com"] == DomainSettings(adBlockingOff: false))

        #expect(d.setAdBlockingOff(true, forHost: "sub.example.com") == "example.com")
        #expect(d.entries == ["*": DomainSettings(adBlockingOff: true)])
        #expect(!d.blocks(on: "sub.example.com"))
    }
}

@Suite struct HistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func store() throws -> History {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("twinkle-\(UUID()).sqlite").path
        return try History(path: path)
    }

    @Test func recordsAndCounts() throws {
        let h = try store()
        try h.recordVisit(url: "https://github.com/", title: "GitHub", at: now)
        try h.recordVisit(url: "https://github.com/", title: "", at: now)
        let all = try h.all()
        #expect(all.count == 1)
        #expect(all[0].visits == 2)
        #expect(all[0].title == "GitHub")
    }

    @Test func forgetOld() throws {
        let h = try store()
        try h.recordVisit(url: "https://old.com/", title: "", at: now.addingTimeInterval(-400 * 86_400))
        try h.recordVisit(url: "https://new.com/", title: "", at: now)
        try h.forget(before: now.addingTimeInterval(-180 * 86_400))
        #expect(try h.all().map(\.url) == ["https://new.com/"])
    }

    func index(_ pages: [(String, String, Int, Double)]) -> HistoryIndex {
        HistoryIndex(pages.map { HistoryEntry(url: $0.0, title: $0.1, visits: $0.2, lastVisit: now.addingTimeInterval(-$0.3 * 86_400)) })
    }

    @Test func fuzzyInOrder() {
        var rows: [Int32] = []
        #expect(Fuzzy.score(Array("ghb".utf8), in: Array("github.com".utf8), rows: &rows) != nil)
        #expect(Fuzzy.score(Array("bhg".utf8), in: Array("github.com".utf8), rows: &rows) == nil)
        // Together and at word starts beats scattered.
        let tight = Fuzzy.score(Array("pull".utf8), in: Array("github.com/a/b/pull/1".utf8), rows: &rows)!
        let loose = Fuzzy.score(Array("pull".utf8), in: Array("example.com/p/u/l/l".utf8), rows: &rows)!
        #expect(tight > loose)
    }

    @Test func everyWordMustMatch() {
        let h = index([("https://news.ycombinator.com/item?id=1", "Swift concurrency explained", 1, 0),
                       ("https://swift.org/", "Swift.org", 1, 0)])
        #expect(h.search("swift concurrency", now: now).map(\.entry.url) == ["https://news.ycombinator.com/item?id=1"])
        #expect(h.search("swift zzz", now: now).isEmpty)
    }

    @Test func typedAddressBeatsMentions() {
        let h = index([("https://news.example.com/github-story", "Why github is down", 20, 0),
                       ("https://github.com/", "GitHub", 1, 3)])
        #expect(h.search("gith", now: now).first?.entry.url == "https://github.com/")
    }

    @Test func abbreviations() {
        let h = index([("https://github.com/apple/swift/pulls", "Pull requests · apple/swift", 2, 1),
                       ("https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer", 2, 1),
                       ("https://example.com/", "Example", 2, 1)])
        #expect(h.search("ghpulls", now: now).first?.entry.url == "https://github.com/apple/swift/pulls")
        #expect(h.search("devswui", now: now).first?.entry.url == "https://developer.apple.com/documentation/swiftui")
    }

    @Test func queryStringsDontMatch() {
        let h = index([("https://accounts.example.com/signin?continue=https://mail.example.com/&flow=GlifWebSignIn", "Sign in", 1, 0)])
        #expect(h.search("glif", now: now).isEmpty)
    }

    @Test func recentBeatsStaleAtEqualVisits() {
        let h = index([("https://a.com/x", "", 5, 90), ("https://a.com/y", "", 5, 0)])
        #expect(h.search("a.com", now: now).first?.entry.url == "https://a.com/y")
    }

    @Test func keepsUpToDate() {
        let h = HistoryIndex()
        h.recordVisit(url: "https://a.com/", title: "", at: now)
        h.setTitle("Alpha", for: "https://a.com/")
        h.recordVisit(url: "https://a.com/", title: "", at: now)
        #expect(h.entry(for: "https://a.com/")?.visits == 2)
        #expect(h.search("alph", now: now).first?.entry.title == "Alpha")
        #expect(HistoryIndex.bare("https://www.GitHub.com/") == "github.com")
        #expect(HistoryIndex.bare("https://github.com/a/") == "github.com/a/")
    }

    @Test func fastOnABigHistory() {
        var pages: [HistoryEntry] = []
        let words = ["swift", "github", "docs", "issue", "pull", "react", "news", "blog", "api", "search"]
        for i in 0..<50_000 {
            let w = words[i % words.count], v = words[(i / 10) % words.count]
            pages.append(HistoryEntry(url: "https://\(w)\(i % 300).example.com/\(v)/\(i)/some-longer-path-here?q=\(i)",
                                      title: "\(v.capitalized) \(w) page number \(i)", visits: 1 + i % 7,
                                      lastVisit: now.addingTimeInterval(-Double(i % 180) * 86_400)))
        }
        let h = HistoryIndex(pages)
        var total = 0.0
        for q in ["s", "sw", "swi", "swif", "swift", "gh is", "docs api 12"] {
            let start = Date()
            _ = h.search(q, now: now)
            let t = Date().timeIntervalSince(start)
            total += t
            print("HistoryIndex: \(q): \(String(format: "%.1f", t * 1000)) ms over 50k pages")
        }
        #expect(total / 7 < 1)   // generous: a debug build is far slower than release
    }

    @Test func sessionsWithoutTabIdsStillLoad() throws {
        let s = try JSONDecoder().decode(Session.self, from: Data(#"{"selected":0,"tabs":[{"url":"https://a.com","title":"A"}]}"#.utf8))
        #expect(s.tabs[0].url == "https://a.com")
    }
}

@Suite struct SafariImportTests {
    /// Builds a Cookies.binarycookies file: big-endian header, one page of
    /// little-endian cookie records.
    func cookieFile(_ cookies: [(domain: String, name: String, path: String, value: String, expires: Double, flags: UInt32)]) -> Data {
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
        func be(_ v: UInt32) -> [UInt8] { le(v).reversed() }
        var records: [[UInt8]] = []
        for c in cookies {
            let strings = [c.domain, c.name, c.path, c.value].map { Array($0.utf8) + [0] }
            var offsets: [UInt32] = []
            var at: UInt32 = 56
            for s in strings { offsets.append(at); at += UInt32(s.count) }
            var r = le(at) + le(0) + le(c.flags) + le(0)
            for o in offsets { r += le(o) }
            r += [UInt8](repeating: 0, count: 8)
            r += withUnsafeBytes(of: c.expires.bitPattern.littleEndian, Array.init)
            r += withUnsafeBytes(of: Double(0).bitPattern.littleEndian, Array.init)
            for s in strings { r += s }
            records.append(r)
        }
        var page = [0, 0, 1, 0] + le(UInt32(records.count))
        var offset = UInt32(8 + 4 * records.count + 4)
        for r in records { page += le(offset); offset += UInt32(r.count) }
        page += [0, 0, 0, 0]
        for r in records { page += r }
        return Data(Array("cook".utf8) + be(1) + be(UInt32(page.count)) + page + [UInt8](repeating: 0, count: 8))
    }

    @Test func readsBinaryCookies() throws {
        let year2030 = Date(timeIntervalSince1970: 1_900_000_000).timeIntervalSinceReferenceDate
        let data = cookieFile([(".github.com", "logged_in", "/", "yes", year2030, 1 | 4),
                               ("example.com", "id", "/app", "42", year2030, 0)])
        let cookies = try Safari.cookies(binary: data)
        #expect(cookies.count == 2)
        #expect(cookies[0] == Safari.Cookie(domain: ".github.com", name: "logged_in", path: "/", value: "yes",
                                           expires: Date(timeIntervalSince1970: 1_900_000_000), secure: true, httpOnly: true))
        #expect(cookies[0].host == "github.com")
        #expect(cookies[1].path == "/app" && !cookies[1].secure && !cookies[1].httpOnly)
        #expect(throws: Safari.Failure.self) { try Safari.cookies(binary: Data("nope".utf8)) }
    }

    @Test func readsBookmarks() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://github.com/", "URIDictionary": ["title": "GitHub"]],
                    ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Work", "Children": [
                        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://linear.app/", "URIDictionary": ["title": "Linear"]],
                        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "javascript:alert(1)", "URIDictionary": ["title": "Bookmarklet"]],
                    ]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://example.com/post", "URIDictionary": ["title": "A post"]],
                ]],
            ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(try Safari.bookmarks(plist: data) == [
            Bookmark(title: "GitHub", url: "https://github.com/"),
            Bookmark(title: "Linear", url: "https://linear.app/"),
            Bookmark(title: "A post", url: "https://example.com/post"),
        ])
    }

    @Test func readsHistoryAndMerges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twinkle-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safari = dir.appendingPathComponent("History.db")
        // Safari's layout, cut down.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [safari.path, """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            INSERT INTO history_items VALUES (1, 'https://github.com/', 7), (2, 'file:///etc/hosts', 1);
            INSERT INTO history_visits VALUES (1, 1, 700000000, 'Old title'), (2, 1, 800000000, 'GitHub'), (3, 2, 800000000, 'hosts');
            """]
        try p.run()
        p.waitUntilExit()
        let pages = try Safari.history(from: safari)
        #expect(pages == [HistoryEntry(url: "https://github.com/", title: "GitHub", visits: 7,
                                       lastVisit: Date(timeIntervalSinceReferenceDate: 800000000))])

        let mine = try History(path: dir.appendingPathComponent("twinkle.sqlite").path)
        try mine.recordVisit(url: "https://github.com/", title: "Mine", at: Date(timeIntervalSinceReferenceDate: 750000000))
        try mine.importPages(pages)
        try mine.importPages(pages + [HistoryEntry(url: "https://new.example/", title: "", visits: 2, lastVisit: .now)])
        let all = try mine.all()
        let gh = all.first { $0.url == "https://github.com/" }!
        #expect(gh.visits == 15 && gh.title == "Mine" && gh.lastVisit == Date(timeIntervalSinceReferenceDate: 800000000))
        #expect(all.count == 2)
    }
}

@Suite struct HTTPStatusTests {
    @Test func text() {
        #expect(HTTPStatus.text(200) == "200 OK")
        #expect(HTTPStatus.text(404) == "404 Not Found")
        #expect(HTTPStatus.text(599) == "599")
    }
}

@Suite struct FileStoreTests {
    @Test func prettyPrintedJSONHasNoSpaceBeforeColonAndPreservesStrings() throws {
        struct Payload: Codable, Equatable {
            var plain: String
            var escaped: String
            var dict: [String: String]
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twinkle-\(UUID())")
        let store = try FileStore(directory: dir)
        let payload = Payload(
            plain: "hello : world",
            escaped: #"foo" : bar and "a" : b"#,
            dict: [#"key" : inside"#: #"val\" : ☕️"#]
        )
        try store.save(payload, to: "test.json")

        let text = try String(contentsOf: store.url("test.json"), encoding: .utf8)
        #expect(text.contains(#""plain": "hello : world""#))
        #expect(text.contains(#""escaped": "foo\" : bar and \"a\" : b""#))
        #expect(text.contains(#""key\" : inside": "val\\\" : ☕️""#))
        #expect(!text.contains(#""plain" :"#))
        #expect(!text.contains(#""dict" :"#))
        #expect(try store.load(Payload.self, from: "test.json") == payload)
    }
}

@Suite struct MarkdownTests {
    @Test func link() {
        let u = { (s: String) in URL(string: s)! }
        #expect(Markdown.link(title: "Example Domain", url: u("https://example.com/")) == "[Example Domain](https://example.com/)")
        #expect(Markdown.link(title: "a [b] \\c", url: u("https://example.com/")) == #"[a \[b\] \\c](https://example.com/)"#)
        #expect(Markdown.link(title: "  ", url: u("https://example.com/x")) == "[example.com](https://example.com/x)")
        #expect(Markdown.link(title: "Wiki", url: u("https://en.wikipedia.org/wiki/Swift_(language)"))
                == "[Wiki](https://en.wikipedia.org/wiki/Swift_%28language%29)")
    }
}
