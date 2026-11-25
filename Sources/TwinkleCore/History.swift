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
/// mode, so a reader never waits on a write.
/// Searching happens in memory: see HistoryIndex.
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

    /// Every page, for the in-memory index (HistoryIndex).
    public func all() throws -> [HistoryEntry] {
        try query("SELECT url, title, visits, last_visit FROM pages ORDER BY last_visit DESC", [])
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
