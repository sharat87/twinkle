import Foundation

/// One WebKit content-blocker rule. The JSON this encodes to is the format
/// WKContentRuleList compiles on macOS, and WebKitGTK's content filters read
/// the same format on Linux.
public struct ContentRule: Encodable, Equatable, Sendable {
    public struct Trigger: Encodable, Equatable, Sendable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var loadContext: [String]?

        public init(urlFilter: String) {
            self.urlFilter = urlFilter
        }

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
        }
    }

    public struct Action: Encodable, Equatable, Sendable {
        public var type: String
        public var selector: String?

        public static let block = Action(type: "block")
        public static let ignorePrevious = Action(type: "ignore-previous-rules")
        public static func hide(_ selector: String) -> Action { Action(type: "css-display-none", selector: selector) }
    }

    public var trigger: Trigger
    public var action: Action
}

/// Converts Adblock Plus / EasyList / uBlock Origin filter syntax, and hosts
/// files, into content-blocker rules.
///
/// Covered: network rules (`||host^`, `|`, `*`, `^`), `@@` exceptions,
/// `$third-party`, `$domain=`, resource types, `$match-case`,
/// `@@…$document`, and element hiding (`##`, `domain##`).
/// Skipped, and counted in `skipped`: regex rules, scriptlets, procedural
/// cosmetic filters (`:has-text` and friends), and options WebKit can't
/// express (`$redirect`, `$csp`, `$removeparam`, …).
public enum FilterConverter {
    /// Bump when the output changes, so compiled lists are rebuilt.
    public static let version = 2
    /// WebKit refuses lists longer than this.
    public static let maxRules = 150_000
    /// Selectors per css-display-none rule. One bad selector can void the
    /// whole group, so groups are kept small.
    static let selectorsPerRule = 64

    public struct Result: Sendable {
        public var rules: [ContentRule]
        public var skipped: Int
    }

    public static func convert(_ text: String) -> Result {
        var blocks: [ContentRule] = []
        var exceptions: [ContentRule] = []
        var pageExceptions: [ContentRule] = []
        var genericHide: [String] = []
        var domainHide: [String: [String]] = [:]
        var domainHideOrder: [String] = []
        var skipped = 0

        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return }
            // Hosts-file comments; `##.ad` (a generic hiding rule) is not one.
            if line == "#" || line.hasPrefix("# ") || line.hasPrefix("#\t") || line.hasPrefix("## ") { return }
            guard line.allSatisfy(\.isASCII) else { skipped += 1; return }

            if isHostsEntry(line) {
                if let domain = hostsFileDomain(line) {
                    blocks += network("||\(domain)^", options: nil, exception: false) ?? []
                }
                return
            }

            // Cosmetic exceptions and extended cosmetic syntaxes.
            if ["#@#", "#?#", "#$#", "#%#", "#@?#", "#@$#", "$$", "#^#"].contains(where: line.contains) {
                skipped += 1
                return
            }
            if let marker = line.range(of: "##") {
                let domains = String(line[..<marker.lowerBound])
                let selector = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard isPlainSelector(selector) else { skipped += 1; return }
                if domains.isEmpty {
                    genericHide.append(selector)
                } else {
                    guard let key = cosmeticDomainKey(domains) else { skipped += 1; return }
                    if domainHide[key] == nil { domainHideOrder.append(key) }
                    domainHide[key, default: []].append(selector)
                }
                return
            }

            var body = Substring(line)
            let exception = body.hasPrefix("@@")
            if exception { body = body.dropFirst(2) }

            var pattern = body
            var options: Substring?
            if let dollar = body.lastIndex(of: "$"), !isRegexRule(body) {
                pattern = body[..<dollar]
                options = body[body.index(after: dollar)...]
            }
            if isRegexRule(pattern) || pattern.contains(where: \.isWhitespace) { skipped += 1; return }

            if exception, let options, let page = pageException(pattern: pattern, options: options) {
                pageExceptions.append(page)
                return
            }
            guard let rules = network(String(pattern), options: options.map(String.init), exception: exception) else {
                skipped += 1
                return
            }
            if exception { exceptions += rules } else { blocks += rules }
        }

        var cosmetic: [ContentRule] = []
        for chunk in chunks(genericHide) {
            cosmetic.append(ContentRule(trigger: .init(urlFilter: ".*"), action: .hide(chunk)))
        }
        for key in domainHideOrder {
            let (ifDomain, unlessDomain) = splitDomainKey(key)
            for chunk in chunks(domainHide[key] ?? []) {
                var trigger = ContentRule.Trigger(urlFilter: ".*")
                trigger.ifDomain = ifDomain
                trigger.unlessDomain = unlessDomain
                cosmetic.append(ContentRule(trigger: trigger, action: .hide(chunk)))
            }
        }

        // Order matters: an ignore-previous-rules rule only cancels the rules
        // before it. Network exceptions cancel network blocks but not element
        // hiding; whole-page ($document) exceptions cancel everything.
        let room = maxRules - blocks.count - exceptions.count - pageExceptions.count
        if cosmetic.count > room {
            skipped += cosmetic.count - max(room, 0)
            cosmetic = Array(cosmetic.prefix(max(room, 0)))
        }
        var rules = blocks + exceptions + cosmetic + pageExceptions
        if rules.count > maxRules {
            skipped += rules.count - maxRules
            rules = Array(rules.prefix(maxRules))
        }
        return Result(rules: rules, skipped: skipped)
    }

    // MARK: Network rules

    static let allResourceTypes = [
        "document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping",
    ]

    static let typeMap: [String: [String]] = [
        "script": ["script"],
        "image": ["image"],
        "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "xmlhttprequest": ["raw"], "xhr": ["raw"],
        "websocket": ["raw"],
        "other": ["raw"], "object": ["raw"], "object-subrequest": ["raw"],
        "subdocument": ["document"], "frame": ["document"],
        "ping": ["ping"], "beacon": ["ping"],
        "popup": ["popup"],
        "document": ["document"], "doc": ["document"],
    ]

    /// Options that change nothing WebKit can express differently.
    static let harmlessOptions: Set<String> = ["important", "all", "~important"]

    /// Usually one rule; two when a trailing `^` has to match either a
    /// separator or the end of the URL (see `urlFilters`).
    static func network(_ pattern: String, options: String?, exception: Bool) -> [ContentRule]? {
        var trigger = ContentRule.Trigger(urlFilter: "")
        var include: [String] = []
        var exclude: Set<String> = []
        var onlySubdocument = false

        for option in (options ?? "").split(separator: ",").map({ $0.lowercased() }) {
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            switch name {
            case _ where harmlessOptions.contains(option):
                continue
            case "third-party", "3p":
                trigger.loadType = [negated ? "first-party" : "third-party"]
            case "first-party", "1p":
                trigger.loadType = [negated ? "third-party" : "first-party"]
            case "match-case":
                trigger.urlFilterIsCaseSensitive = negated ? nil : true
            case _ where name.hasPrefix("domain="):
                guard !negated else { return nil }
                let (ifDomain, unlessDomain) = domains(String(name.dropFirst("domain=".count)), separator: "|")
                if ifDomain == nil && unlessDomain == nil { return nil }
                trigger.ifDomain = ifDomain
                trigger.unlessDomain = ifDomain == nil ? unlessDomain : nil
            default:
                guard let types = typeMap[name] else { return nil }
                if negated {
                    exclude.formUnion(types)
                } else {
                    include.append(contentsOf: types)
                    if name == "subdocument" || name == "frame" { onlySubdocument = true }
                }
            }
        }

        if !include.isEmpty {
            let unique = Array(NSOrderedSet(array: include)) as? [String] ?? include
            trigger.resourceType = unique
            if unique == ["document"] && onlySubdocument { trigger.loadContext = ["child-frame"] }
        } else if !exclude.isEmpty {
            let rest = allResourceTypes.filter { !exclude.contains($0) }
            guard !rest.isEmpty else { return nil }
            trigger.resourceType = rest
        }

        guard let filters = urlFilters(pattern) else { return nil }
        // A rule that matches every URL is only acceptable when something
        // else narrows it, like `*$script,domain=example.com`.
        if filters.contains(".*") && trigger.ifDomain == nil { return nil }
        return filters.map { filter in
            var t = trigger
            t.urlFilter = filter
            return ContentRule(trigger: t, action: exception ? .ignorePrevious : .block)
        }
    }

    /// `@@||example.com^$document`: nothing is blocked on that site's pages.
    static func pageException(pattern: Substring, options: Substring) -> ContentRule? {
        let names = Set(options.split(separator: ",").map { $0.lowercased() })
        guard names.contains("document") || names.contains("doc") else { return nil }
        guard let domain = anchoredDomain(pattern) else { return nil }
        var trigger = ContentRule.Trigger(urlFilter: ".*")
        trigger.ifDomain = ["*" + domain]
        return ContentRule(trigger: trigger, action: .ignorePrevious)
    }

    /// `||example.com^` → `example.com`.
    static func anchoredDomain(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var d = pattern.dropFirst(2)
        while let last = d.last, "^/|".contains(last) { d = d.dropLast() }
        let domain = d.lowercased()
        guard !domain.isEmpty, domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return domain
    }

    /// Adblock pattern → url-filters, in the regex subset WebKit accepts:
    /// `.`, `*`, `+`, `?`, character classes, groups, `^` and `$` anchors.
    /// No alternation and no `{n}`.
    ///
    /// A trailing `^` means "a separator or the end of the URL". Without
    /// alternation the faithful regex is `(sep.*)?$`, but tens of thousands of
    /// those make WebKit's NFA→DFA step ~12× slower (18 s vs 1.5 s for
    /// EasyList). So it becomes a plain separator, plus a second `$`-anchored
    /// rule for the end-of-URL case. `||domain^` needs no second rule: WebKit
    /// URLs always have a `/` or `:` after the host.
    static func urlFilters(_ pattern: String) -> [String]? {
        guard let filter = urlFilter(pattern) else { return nil }
        let p = pattern.hasSuffix("|") ? String(pattern.dropLast()) : pattern
        guard pattern.hasSuffix("^"), anchoredDomain(Substring(p)) == nil else { return [filter] }
        let separator = "[^a-z0-9_.%-]"
        guard filter.hasSuffix(separator) else { return [filter] }
        return [filter, String(filter.dropLast(separator.count)) + "$"]
    }

    static func urlFilter(_ pattern: String) -> String? {
        var p = Substring(pattern)
        var out = ""
        if p.hasPrefix("||") {
            p = p.dropFirst(2)
            out = "^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?"
        } else if p.hasPrefix("|") {
            p = p.dropFirst()
            out = "^"
        }
        var anchoredEnd = false
        if p.hasSuffix("|") {
            p = p.dropLast()
            anchoredEnd = true
        }
        if out == "^" { while p.hasPrefix("*") { p = p.dropFirst(); out = "" } }

        let separator = "[^a-z0-9_.%-]"
        for c in p {
            switch c {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                out += separator
            case "|", "{", "}":
                return nil
            case ".", "+", "?", "(", ")", "[", "]", "\\", "$":
                out += "\\" + String(c)
            default:
                out.append(c)
            }
        }
        if anchoredEnd { out += "$" }
        // Leading and trailing `.*` add nothing: url-filter searches.
        while out.hasPrefix(".*") && out.count > 2 { out.removeFirst(2) }
        while out.hasSuffix(".*") && out.count > 2 && !out.hasSuffix("\\.*") { out.removeLast(2) }
        if out.isEmpty { out = ".*" }
        return out
    }

    static func isRegexRule<S: StringProtocol>(_ s: S) -> Bool {
        s.count > 2 && s.hasPrefix("/") && (s.hasSuffix("/") || s.contains("/$"))
    }

    static let hostsAddresses: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1"]

    static func isHostsEntry(_ line: String) -> Bool {
        guard let first = line.split(whereSeparator: \.isWhitespace).first else { return false }
        return hostsAddresses.contains(String(first)) && line.contains(where: \.isWhitespace)
    }

    /// `0.0.0.0 tracker.example` or `127.0.0.1 tracker.example`.
    static func hostsFileDomain(_ line: String) -> String? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, hostsAddresses.contains(String(parts[0])) else { return nil }
        let domain = parts[1].lowercased()
        let ignored: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "0.0.0.0", "ip6-localhost", "ip6-loopback"]
        guard !ignored.contains(domain),
              domain.contains("."),
              domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return domain
    }

    // MARK: Domains

    /// `a.com|~b.a.com` → if-domain / unless-domain values. WebKit can't mix
    /// the two in one trigger, so when both appear the positive ones win and
    /// the rule applies a little more widely than written.
    static func domains(_ spec: String, separator: Character) -> (ifDomain: [String]?, unlessDomain: [String]?) {
        var include: [String] = []
        var exclude: [String] = []
        for part in spec.split(separator: separator).map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            let negated = part.hasPrefix("~")
            let domain = negated ? String(part.dropFirst()) : part
            // WebKit has no wildcard TLDs (`google.*`).
            guard !domain.isEmpty, !domain.contains("*"),
                  domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
            else { continue }
            if negated { exclude.append("*" + domain) } else { include.append("*" + domain) }
        }
        if !include.isEmpty { return (include, nil) }
        if !exclude.isEmpty { return (nil, exclude) }
        return (nil, nil)
    }

    /// Cosmetic rules are grouped by their domain list; the key is that list
    /// normalised, or nil when nothing usable is left.
    static func cosmeticDomainKey(_ spec: String) -> String? {
        let (ifDomain, unlessDomain) = domains(spec, separator: ",")
        if let ifDomain { return "+" + ifDomain.sorted().joined(separator: ",") }
        if let unlessDomain { return "-" + unlessDomain.sorted().joined(separator: ",") }
        return nil
    }

    static func splitDomainKey(_ key: String) -> ([String]?, [String]?) {
        let list = key.dropFirst().split(separator: ",").map(String.init)
        return key.hasPrefix("+") ? (list, nil) : (nil, list)
    }

    // MARK: Element hiding

    static let proceduralMarkers = [
        ":-abp-", ":has-text(", ":contains(", ":xpath(", ":style(", ":remove(", ":matches-css",
        ":upward(", ":watch-attr(", ":min-text-length(", ":matches-path(", ":matches-attr(",
        ":matches-prop(", ":others(", ":if(", ":if-not(", ":nth-ancestor(", ":remove-attr(",
        ":remove-class(", ":matches-media(", ":shadow-dom", "+js(",
    ]

    static func isPlainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, !selector.hasPrefix("+js"), !selector.hasPrefix("^") else { return false }
        if selector.contains("{") || selector.contains("}") { return false }
        return !proceduralMarkers.contains(where: selector.contains)
    }

    static func chunks(_ selectors: [String]) -> [String] {
        stride(from: 0, to: selectors.count, by: selectorsPerRule).map {
            selectors[$0..<min($0 + selectorsPerRule, selectors.count)].joined(separator: ", ")
        }
    }
}

/// A small list used until the real lists have downloaded, and alongside them.
public enum BuiltinFilters {
    public static let text = """
    ! Twinkle's starter list: well-known ad and tracking networks.
    ||doubleclick.net^$third-party
    ||googlesyndication.com^$third-party
    ||googleadservices.com^$third-party
    ||googletagservices.com^$third-party
    ||google-analytics.com^$third-party
    ||googletagmanager.com^$third-party
    ||adservice.google.com^$third-party
    ||amazon-adsystem.com^$third-party
    ||adnxs.com^$third-party
    ||adsrvr.org^$third-party
    ||criteo.com^$third-party
    ||criteo.net^$third-party
    ||taboola.com^$third-party
    ||outbrain.com^$third-party
    ||rubiconproject.com^$third-party
    ||pubmatic.com^$third-party
    ||openx.net^$third-party
    ||casalemedia.com^$third-party
    ||smartadserver.com^$third-party
    ||moatads.com^$third-party
    ||adroll.com^$third-party
    ||scorecardresearch.com^$third-party
    ||quantserve.com^$third-party
    ||hotjar.com^$third-party
    ||mouseflow.com^$third-party
    ||fullstory.com^$third-party
    ||clarity.ms^$third-party
    ||connect.facebook.net^$third-party
    ||bat.bing.com^$third-party
    ||ads-twitter.com^$third-party
    ||analytics.tiktok.com^$third-party
    ||segment.io^$third-party
    ||cdn.segment.com^$third-party
    ||mixpanel.com^$third-party
    ||amplitude.com^$third-party
    ||branch.io^$third-party
    ||yieldmo.com^$third-party
    ||media.net^$third-party
    ||zedo.com^$third-party
    ||serving-sys.com^$third-party
    """
}
