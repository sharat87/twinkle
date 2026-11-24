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
}

@Suite struct WindowTitleTests {
    let format = Settings().windowTitleFormat

    @Test func titleAndHost() {
        let title = WindowTitle.make(title: "Sign in", url: URL(string: "https://accounts.example.com/login"), format: format)
        #expect(title == "Sign in - accounts.example.com")
    }

    @Test func noPageTitleUsesHost() {
        let title = WindowTitle.make(title: " ", url: URL(string: "https://example.com"), format: format)
        #expect(title == "example.com - example.com")
    }

    @Test func blankTab() {
        #expect(WindowTitle.make(title: "", url: nil, format: format) == "Twinkle")
    }

    @Test func tokensInTitleAreNotExpanded() {
        let title = WindowTitle.make(title: "{host}", url: URL(string: "https://a.com"), format: "{title} | {host} | {nope}")
        #expect(title == "{host} | a.com | {nope}")
    }
}

@Suite struct SettingsTests {
    @Test func partialFileKeepsDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"adBlocking": false}"#.utf8))
        #expect(s.adBlocking == false)
        #expect(s.searchURL == Settings().searchURL)
    }

    @Test func blockingOffForSubdomains() {
        var s = Settings()
        s.adBlockingOffFor = ["example.com"]
        #expect(!s.blocks(on: "www.example.com"))
        #expect(!s.blocks(on: "example.com"))
        #expect(s.blocks(on: "notexample.com"))
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
