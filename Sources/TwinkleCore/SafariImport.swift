import Foundation
import SQLite3

/// Reading Safari's history, bookmarks and cookies, for a one-off import.
/// macOS keeps these files behind Full Disk Access.
public enum Safari {
    public static var home: URL { Home.url }
    public static var historyFile: URL { home.appendingPathComponent("Library/Safari/History.db") }
    public static var bookmarksFile: URL { home.appendingPathComponent("Library/Safari/Bookmarks.plist") }
    public static var cookieFiles: [URL] {
        [home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
         home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")]
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String), format(String)
        public var description: String {
            switch self {
            case .unreadable(let s): "can't read \(s)"
            case .format(let s): s
            }
        }
    }

    // MARK: History

    /// Every web page in Safari's history: visit count, last visit and the
    /// latest title. Read from a copy, since Safari keeps the database open.
    public static func history(from file: URL = historyFile) throws -> [HistoryEntry] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("twinkle-safari-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("History.db")
        do {
            try fm.copyItem(at: file, to: copy)
        } catch {
            throw Failure.unreadable(file.path)
        }
        for suffix in ["-wal", "-shm"] {
            try? fm.copyItem(at: URL(fileURLWithPath: file.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure.format("Safari's History.db won't open")
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT i.url, i.visit_count, MAX(v.visit_time),
               (SELECT title FROM history_visits t WHERE t.history_item = i.id AND t.title != ''
                ORDER BY t.visit_time DESC LIMIT 1)
        FROM history_items i JOIN history_visits v ON v.history_item = i.id
        GROUP BY i.id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.format("Safari's history isn't laid out as expected: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            let url = text(0)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            entries.append(HistoryEntry(
                url: url, title: text(3), visits: max(1, Int(sqlite3_column_int64(statement, 1))),
                lastVisit: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))))
        }
        return entries
    }

    // MARK: Bookmarks

    /// Bookmarks in order, folders flattened away.
    public static func bookmarks(from file: URL = bookmarksFile) throws -> [Bookmark] {
        guard let data = try? Data(contentsOf: file) else { throw Failure.unreadable(file.path) }
        return try bookmarks(plist: data)
    }

    public static func bookmarks(plist data: Data) throws -> [Bookmark] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.format("Safari's Bookmarks.plist isn't laid out as expected")
        }
        var found: [Bookmark] = []
        func walk(_ node: [String: Any]) {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = node["URLString"] as? String, url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                found.append(Bookmark(title: title, url: url))
            case "WebBookmarkTypeList":
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
            default:
                return   // the History proxy and the like
            }
        }
        walk(root)
        return found
    }

    // MARK: Cookies

    public struct Cookie: Equatable, Sendable {
        public var domain: String
        public var name: String
        public var path: String
        public var value: String
        public var expires: Date
        public var secure: Bool
        public var httpOnly: Bool

        /// The host to look up a container for: without the leading dot.
        public var host: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }
    }

    /// Reads Cookies.binarycookies: a big-endian header listing pages, each
    /// page a little-endian list of cookie records with offsets to their
    /// strings. Dates count seconds from 2001.
    public static func cookies(binary data: Data) throws -> [Cookie] {
        let bytes = [UInt8](data)
        func be32(_ at: Int) throws -> Int {
            guard at + 4 <= bytes.count else { throw Failure.format("cookie file is truncated") }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func le32(_ at: Int) throws -> Int {
            guard at + 4 <= bytes.count else { throw Failure.format("cookie file is truncated") }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func double(_ at: Int) throws -> Double {
            guard at + 8 <= bytes.count else { throw Failure.format("cookie file is truncated") }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: bits)
        }
        func string(_ at: Int, end: Int) -> String {
            guard at >= 0, at < end else { return "" }
            var stop = at
            while stop < end, bytes[stop] != 0 { stop += 1 }
            return String(decoding: bytes[at..<stop], as: UTF8.self)
        }

        guard bytes.count >= 8, bytes[0..<4].elementsEqual("cook".utf8) else {
            throw Failure.format("not a Safari cookie file")
        }
        let pageCount = try be32(4)
        var sizes: [Int] = []
        for i in 0..<pageCount { sizes.append(try be32(8 + 4 * i)) }
        var page = 8 + 4 * pageCount
        var cookies: [Cookie] = []
        for size in sizes {
            let end = min(page + size, bytes.count)
            let count = try le32(page + 4)
            for i in 0..<count {
                let start = page + (try le32(page + 8 + 4 * i))
                let length = try le32(start)
                let stop = min(start + length, end)
                let flags = try le32(start + 8)
                cookies.append(Cookie(
                    domain: string(start + (try le32(start + 16)), end: stop),
                    name: string(start + (try le32(start + 20)), end: stop),
                    path: string(start + (try le32(start + 24)), end: stop),
                    value: string(start + (try le32(start + 28)), end: stop),
                    expires: Date(timeIntervalSinceReferenceDate: try double(start + 40)),
                    secure: flags & 1 != 0,
                    httpOnly: flags & 4 != 0))
            }
            page += size
        }
        return cookies
    }
}

/// A bookmark: bookmarks.json is one flat list, searched by the address
/// bar above plain history.
public struct Bookmark: Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    public static let file = "bookmarks.json"
}
