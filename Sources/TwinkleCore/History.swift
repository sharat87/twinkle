import Foundation
import SQLite3

/// One page in the history.
public struct HistoryEntry: Equatable, Sendable {
    public var url: String
    public var title: String
    public var visits: Int
    public var lastVisit: Date

    public init(url: String, title: String, visits: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visits = visits
        self.lastVisit = lastVisit
    }

    public var host: String { URL(string: url)?.host(percentEncoded: false) ?? "" }
}

/// `history.sqlite`: every page visited, one row per address. SQLite in WAL
/// mode, so the Alfred helper can read it while Twinkle writes.
///
/// Searching matches every word of the query against the address and title,
/// then ranks by how well and where it matched (the start of the host beats
/// the middle of a path) and by how often and how lately the page was
/// visited.
public final class History {
    private var db: OpaquePointer?

    public enum Failure: Error { case open(String), sql(String) }

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw Failure.open(message)
        }
        sqlite3_busy_timeout(db, 500)
        if !readOnly {
            try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS pages (
                url TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                visits INTEGER NOT NULL DEFAULT 0,
                last_visit REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS pages_last_visit ON pages (last_visit);
            """)
        }
    }

    deinit { sqlite3_close(db) }

    /// Counts a visit to `url`.
    public func recordVisit(url: String, title: String, at date: Date = Date()) throws {
        try run("""
        INSERT INTO pages (url, title, visits, last_visit) VALUES (?1, ?2, 1, ?3)
        ON CONFLICT (url) DO UPDATE SET visits = visits + 1, last_visit = ?3,
            title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
        """, [url, title, date.timeIntervalSince1970])
    }

    /// Pages often get their title after they load.
    public func setTitle(_ title: String, for url: String) throws {
        guard !title.isEmpty else { return }
        try run("UPDATE pages SET title = ?2 WHERE url = ?1", [url, title])
    }

    public func forgetAll() throws {
        try exec("DELETE FROM pages; VACUUM;")
    }

    /// Drops pages not visited since `date`.
    public func forget(before date: Date) throws {
        try run("DELETE FROM pages WHERE last_visit < ?1", [date.timeIntervalSince1970])
    }

    /// The best `limit` matches for `text`. Empty text: the most visited
    /// recent pages.
    public func search(_ text: String, limit: Int = 12, now: Date = Date()) throws -> [HistoryEntry] {
        let words = HistoryRanking.words(text)
        var sql = "SELECT url, title, visits, last_visit FROM pages"
        var args: [Any] = []
        if !words.isEmpty {
            sql += " WHERE " + words.indices.map { "(url LIKE ?\($0 + 1) ESCAPE '\\' OR title LIKE ?\($0 + 1) ESCAPE '\\')" }
                .joined(separator: " AND ")
            args = words.map { "%" + Self.escapeLike($0) + "%" }
        }
        // Enough candidates to rank; the newest win if there are too many.
        sql += " ORDER BY last_visit DESC LIMIT 2000"
        let rows = try query(sql, args)
        return HistoryRanking.rank(rows, words: words, now: now).prefix(limit).map { $0 }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: SQLite

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "error"
            sqlite3_free(error)
            throw Failure.sql(message)
        }
    }

    private func prepare(_ sql: String, _ args: [Any]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(statement, index, s, -1, transient)
            case let d as Double: sqlite3_bind_double(statement, index, d)
            case let n as Int: sqlite3_bind_int64(statement, index, Int64(n))
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ args: [Any]) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ args: [Any]) throws -> [HistoryEntry] {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var rows: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            rows.append(HistoryEntry(url: text(0), title: text(1), visits: Int(sqlite3_column_int64(statement, 2)),
                                     lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return rows
    }
}

/// How history matches are ordered. Separate from the database so it can
/// be tested on its own.
public enum HistoryRanking {
    public static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func rank(_ entries: [HistoryEntry], words: [String], now: Date) -> [HistoryEntry] {
        entries.map { ($0, score($0, words: words, now: now)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// How often and how lately: visits count less the more there are, and
    /// a visit a month ago counts about a quarter of one today.
    public static func frecency(_ e: HistoryEntry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(e.lastVisit) / 86_400)
        return log2(1 + Double(e.visits)) * (1 / (1 + days / 10))
    }

    public static func score(_ e: HistoryEntry, words: [String], now: Date) -> Double {
        let base = 0.05 + frecency(e, now: now)
        guard !words.isEmpty else { return base }
        let url = e.url.lowercased()
        let host = Hosts.siteKey(e.host)
        let title = e.title.lowercased()
        // What the address looks like typed: no scheme, no www.
        var bare = Substring(url)
        if let r = bare.range(of: "://") { bare = bare[r.upperBound...] }
        if bare.hasPrefix("www.") { bare = bare.dropFirst(4) }

        var match = 1.0
        for (i, word) in words.enumerated() {
            if i == 0 && bare.hasPrefix(word) {
                match *= 8                         // typing the address itself
            } else if host.contains(word) {
                match *= host.split(separator: ".").contains { $0.hasPrefix(word) } ? 4 : 2.5
            } else if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) {
                match *= 2                         // the start of a word in the title
            } else if url.contains(word) || title.contains(word) {
                match *= 1
            } else {
                return 0
            }
        }
        // Site roots first among equals: "github.com" before a deep link.
        let path = URL(string: e.url)?.path ?? ""
        if path.isEmpty || path == "/" { match *= 1.5 }
        return base * match
    }
}
