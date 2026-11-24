// twinkle-query: the Alfred workflow's script filter.
//
//   twinkle-query "<what was typed>"
//
// Prints Alfred script-filter JSON: first what was typed (as an address or
// a search), then open tabs that match, then history. Each result's `arg`
// is a twinkle:// link the workflow opens, which Twinkle acts on:
//
//   twinkle://open?input=<text>            in the current tab
//   twinkle://open?input=<text>&tab=new    in a new tab (⌘↩)
//   twinkle://switch?tab=<id>              bring an open tab to the front
import CryptoKit
import Foundation
import TwinkleCore

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Twinkle", isDirectory: true)
let files = try? FileStore(directory: support)
let settings = (try? files?.load(Settings.self, from: "settings.json")) ?? Settings()
let session = (try? files?.load(Session.self, from: "session.json")) ?? Session(tabs: [], selected: 0)

let text = CommandLine.arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
let words = HistoryRanking.words(text)

func link(_ action: String, _ params: [(String, String)]) -> String {
    var c = URLComponents()
    c.scheme = "twinkle"
    c.host = action
    c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
    // `+` and `&` inside values must survive the trip.
    c.percentEncodedQuery = c.percentEncodedQuery?
        .replacingOccurrences(of: "+", with: "%2B")
    return c.string ?? "twinkle://open"
}

func icon(for url: String) -> [String: String]? {
    guard let host = URL(string: url)?.host()?.lowercased() else { return nil }
    let name = SHA256.hash(data: Data(host.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
    let path = support.appendingPathComponent("favicons").appendingPathComponent(name).path
    return FileManager.default.fileExists(atPath: path) ? ["path": path] : nil
}

func page(_ url: String, title: String, subtitle: String? = nil, arg: String? = nil) -> [String: Any] {
    var item: [String: Any] = [
        "title": title.isEmpty ? url : title,
        "subtitle": subtitle ?? url,
        "arg": arg ?? link("open", [("input", url)]),
        "autocomplete": url,
        "quicklookurl": url,
        "text": ["copy": url, "largetype": url],
        "mods": ["cmd": ["arg": link("open", [("input", url), ("tab", "new")]), "subtitle": "Open in a new tab"]],
    ]
    if let icon = icon(for: url) { item["icon"] = icon }
    return item
}

var items: [[String: Any]] = []
var shown = Set<String>()
var typed: [String: Any]?

// What was typed, as an address or a search.
if !text.isEmpty, let target = Address.resolve(text, searchTemplate: settings.searchURL) {
    let isSearch = Address.asURL(text) == nil
    let engine = URL(string: settings.searchURL)?.host() ?? "the web"
    typed = [
        "title": isSearch ? "Search for “\(text)”" : target.absoluteString,
        "subtitle": isSearch ? "Search \(engine)" : "Open",
        "arg": link("open", [("input", text)]),
        "autocomplete": text,
        "mods": ["cmd": ["arg": link("open", [("input", text), ("tab", "new")]), "subtitle": "In a new tab"]],
    ]
    shown.insert(target.absoluteString)
}

// Open tabs.
// Ranked like history, so github.com comes before a deep GitHub link.
let now = Date()
let tabs = words.isEmpty ? [] : session.tabs
    .map { ($0, HistoryRanking.score(HistoryEntry(url: $0.url, title: $0.title, visits: 1, lastVisit: now), words: words, now: now)) }
    .filter { $0.1 > 0 }
    .sorted { $0.1 > $1.1 }
    .map(\.0)
for tab in tabs.prefix(5) where !shown.contains(tab.url) {
    var item = page(tab.url, title: tab.title, subtitle: "Switch to tab · \(tab.url)",
                    arg: link("switch", [("tab", tab.id.uuidString)]))
    item["mods"] = nil
    items.append(item)
    shown.insert(tab.url)
}

// History.
let historyPath = support.appendingPathComponent("history.sqlite").path
if FileManager.default.fileExists(atPath: historyPath), let history = try? History(path: historyPath, readOnly: true) {
    for entry in (try? history.search(text, limit: 15)) ?? [] where !shown.contains(entry.url) {
        items.append(page(entry.url, title: entry.title))
        shown.insert(entry.url)
    }
}

/// The address as you'd type it: no scheme, no www.
func bare(_ url: String) -> String {
    var s = Substring(url.lowercased())
    if let r = s.range(of: "://") { s = s[r.upperBound...] }
    if s.hasPrefix("www.") { s = s.dropFirst(4) }
    return String(s)
}

// What was typed goes first, unless it's the start of a known address
// ("git" → github.com): then that address leads, as Safari's top hit.
if let typed {
    let leads = items.first.flatMap { $0["autocomplete"] as? String }.map { bare($0).hasPrefix(text.lowercased()) } ?? false
    items.insert(typed, at: leads ? 1 : 0)
}

let output: [String: Any] = ["items": items]
let data = try JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
