import Foundation

/// Sublime Text–style fuzzy matching: the letters typed must appear in order,
/// not necessarily together. Matches score higher when they're consecutive
/// and when they start words (after `/`, `.`, `-`, a space…), and lower the
/// more they're spread out. `gh` finds github.com, `ghpr` finds
/// github.com/…/pulls/….
///
/// Works on lowercased UTF-8 bytes with a two-row dynamic program, so a
/// pass over tens of thousands of pages takes a few milliseconds.
public enum Fuzzy {
    static let match: Int32 = 16
    static let boundary: Int32 = 10
    static let consecutive: Int32 = 8
    static let gapStart: Int32 = 3
    static let gapExtend: Int32 = 1
    static let none = Int32.min / 4

    /// Word-start bonus for the byte at `j`.
    @inline(__always)
    static func bonus(_ t: UnsafeBufferPointer<UInt8>, _ j: Int) -> Int32 {
        if j == 0 { return boundary + 4 }
        switch t[j - 1] {
        case UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: " "),
             UInt8(ascii: ":"), UInt8(ascii: "?"), UInt8(ascii: "="), UInt8(ascii: "&"), UInt8(ascii: "#"),
             UInt8(ascii: "+"), UInt8(ascii: "~"), UInt8(ascii: "@"), UInt8(ascii: "("), UInt8(ascii: "|"),
             UInt8(ascii: ","):
            return boundary
        default:
            return 0
        }
    }

    /// The best score for `pattern` in `text`, or nil if it doesn't match.
    /// `rows` is scratch space, reused between calls.
    public static func score(_ pattern: [UInt8], in text: [UInt8], rows: inout [Int32]) -> Int32? {
        let n = pattern.count, m = text.count
        guard n > 0, n <= m else { return n == 0 ? 0 : nil }
        return text.withUnsafeBufferPointer { t in
            pattern.withUnsafeBufferPointer { p in
                // Cheap rejection, and the window the match can be in: from
                // the first place it can start to the last place it can end.
                var first = -1, i = 0
                for j in 0..<m where t[j] == p[i] {
                    if i == 0 { first = j }
                    i += 1
                    if i == n { break }
                }
                guard i == n else { return nil }
                var last = m - 1
                i = n - 1
                while last >= first {
                    if t[last] == p[i] { break }
                    last -= 1
                }
                let width = last - first + 1
                if rows.count < 2 * width { rows = [Int32](repeating: 0, count: 2 * width) }
                return rows.withUnsafeMutableBufferPointer { buffer -> Int32? in
                    var prev = buffer.baseAddress!, cur = prev + width
                    for i in 0..<n {
                        var carry = none
                        let c = p[i]
                        for k in 0..<width {
                            let j = first + k
                            var best = none
                            if t[j] == c {
                                let b = bonus(t, j)
                                if i == 0 {
                                    // A little against starting deep in the text.
                                    best = match + b * 2 - Int32(min(j, 24) / 2)
                                } else {
                                    if k > 0, prev[k - 1] > none {
                                        best = prev[k - 1] + match + max(b, consecutive)
                                    }
                                    if carry > none { best = max(best, carry + match + b) }
                                }
                            }
                            if i > 0 {
                                // Predecessors two or more back, gap penalty paid.
                                let skip = k > 0 && prev[k - 1] > none ? prev[k - 1] - gapStart : none
                                carry = max(carry > none ? carry - gapExtend : none, skip)
                            }
                            cur[k] = best
                        }
                        swap(&prev, &cur)
                    }
                    var top = none
                    for k in 0..<width where prev[k] > top { top = prev[k] }
                    return top > none ? top : nil
                }
            }
        }
    }
}

/// History, in memory, for the address bar's suggestions. Loaded from
/// history.sqlite once and kept up to date as pages are visited, so typing
/// never waits on the disk.
public final class HistoryIndex {
    public struct Match: Equatable {
        public var entry: HistoryEntry
        public var score: Int
    }

    struct Item {
        var entry: HistoryEntry
        var bare: [UInt8]
        var title: [UInt8]
        var isRoot: Bool

        init(_ entry: HistoryEntry) {
            self.entry = entry
            let b = HistoryIndex.bare(entry.url)
            // Matched without the query string: tracking and redirect
            // parameters would otherwise match almost anything. Search
            // pages still match by their titles.
            bare = Array((b.firstIndex { $0 == "?" || $0 == "#" }.map { b[..<$0] } ?? b[...]).utf8)
            title = Array(entry.title.lowercased().utf8)
            isRoot = !b.contains("/")
        }
    }

    private var items: [Item] = []
    private var positions: [String: Int] = [:]
    private var rows: [Int32] = []
    /// The last search's words and the pages that matched them. Typing more
    /// only narrows a fuzzy match, so the next search starts from these.
    private var lastWords: [[UInt8]] = []
    private var lastMatches: [Int]?

    public init(_ entries: [HistoryEntry] = []) {
        items.reserveCapacity(entries.count)
        for e in entries where positions[e.url] == nil {
            positions[e.url] = items.count
            items.append(Item(e))
        }
    }

    public var count: Int { items.count }

    /// An address as it's typed: lowercased, no scheme, no `www.`, no
    /// trailing slash on a site's root.
    public static func bare(_ url: String) -> String {
        var s = Substring(url.lowercased())
        if let r = s.range(of: "://") { s = s[r.upperBound...] }
        if s.hasPrefix("www.") { s = s.dropFirst(4) }
        if s.hasSuffix("/"), s.dropLast().firstIndex(of: "/") == nil { s = s.dropLast() }
        return String(s)
    }

    public func recordVisit(url: String, title: String, at date: Date = Date()) {
        if let i = positions[url] {
            items[i].entry.visits += 1
            items[i].entry.lastVisit = date
            if !title.isEmpty, title != items[i].entry.title { setTitle(title, for: url) }
        } else {
            positions[url] = items.count
            items.append(Item(HistoryEntry(url: url, title: title, visits: 1, lastVisit: date)))
            lastMatches = nil
        }
    }

    public func setTitle(_ title: String, for url: String) {
        guard !title.isEmpty, let i = positions[url] else { return }
        items[i].entry.title = title
        items[i].title = Array(title.lowercased().utf8)
        lastMatches = nil
    }

    public func entry(for url: String) -> HistoryEntry? {
        positions[url].map { items[$0].entry }
    }

    public func removeAll() {
        items.removeAll()
        positions.removeAll()
        lastMatches = nil
    }

    public static func words(_ text: String) -> [[UInt8]] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    /// The best `limit` pages for what was typed.
    public func search(_ text: String, limit: Int = 12, now: Date = Date()) -> [Match] {
        let words = Self.words(text)
        guard !words.isEmpty else { return [] }
        var top: [Match] = []
        top.reserveCapacity(limit + 1)
        var floor = Int.min
        let nowSeconds = now.timeIntervalSince1970
        let narrows = lastMatches != nil && words.count >= lastWords.count
            && zip(words, lastWords).allSatisfy { $0.starts(with: $1) }
        let candidates = narrows ? lastMatches! : Array(items.indices)
        var matched: [Int] = []
        for index in candidates {
            guard let s = Self.score(items[index], words: words, now: nowSeconds, rows: &rows) else { continue }
            matched.append(index)
            let item = items[index]
            if top.count == limit && s <= floor { continue }
            // Insert in order; the list is short.
            let at = top.firstIndex { $0.score < s } ?? top.count
            top.insert(Match(entry: item.entry, score: s), at: at)
            if top.count > limit { top.removeLast() }
            if top.count == limit { floor = top[limit - 1].score }
        }
        lastWords = words
        lastMatches = matched
        return top
    }

    /// The same scoring for a page that isn't in history (an open tab).
    public func score(_ entry: HistoryEntry, text: String, now: Date = Date()) -> Int? {
        Self.score(Item(entry), words: Self.words(text), now: now.timeIntervalSince1970, rows: &rows)
    }

    /// Every word has to match the address or the title. Then: how well
    /// (fuzzy score), whether the address starts with what was typed, how
    /// often and lately the page was visited, and site roots before deep
    /// links.
    static func score(_ item: borrowing Item, words: [[UInt8]], now: TimeInterval, rows: inout [Int32]) -> Int? {
        guard !words.isEmpty else { return nil }
        var total: Int32 = 0
        for word in words {
            let inURL = Fuzzy.score(word, in: item.bare, rows: &rows)
            let inTitle = Fuzzy.score(word, in: item.title, rows: &rows)
            switch (inURL, inTitle) {
            case let (u?, t?): total += max(u, t - 6)
            case let (u?, nil): total += u
            case let (nil, t?): total += t - 6
            case (nil, nil): return nil
            }
        }
        var score = Int(total)
        if item.bare.starts(with: words[0]) { score += 40 }
        if item.isRoot { score += 12 }
        let days = max(0, (now - item.entry.lastVisit.timeIntervalSince1970) / 86_400)
        score += Int(14 * log2(1 + Double(item.entry.visits)) / (1 + days / 10))
        score -= item.bare.count / 20
        return score
    }

    /// How often and how lately: visits count less the more there are, and
    /// a visit a month ago counts about a quarter of one today.
    public static func frecency(_ e: HistoryEntry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(e.lastVisit) / 86_400)
        return log2(1 + Double(e.visits)) * (1 / (1 + days / 10))
    }
}
