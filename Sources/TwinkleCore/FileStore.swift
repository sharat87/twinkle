import Foundation

/// Plain JSON files in one folder. Everything Twinkle keeps is a file you can
/// read, edit, diff and back up.
public struct FileStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// nil when the file doesn't exist. Throws when it exists but doesn't
    /// parse, so a typo in a hand-edited file is reported, not overwritten.
    public func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        guard exists(name) else { return nil }
        let data = try Data(contentsOf: url(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = Self.compactColons(try encoder.encode(value))
        data.append(0x0A)
        try data.write(to: url(name), options: .atomic)
    }

    /// Strips the space before `:` that `JSONEncoder`'s `.prettyPrinted` adds
    /// after object keys, without touching string literal contents.
    static func compactColons(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var inString = false
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            let next = data.index(after: i)
            if inString {
                out.append(byte)
                if byte == 0x5C, next < data.endIndex {
                    out.append(data[next])
                    i = data.index(after: next)
                    continue
                }
                if byte == 0x22 { inString = false }
            } else if byte == 0x20, out.last == 0x22, next < data.endIndex, data[next] == 0x3A {
                // Drop the space in `"key" : value`.
            } else {
                out.append(byte)
                if byte == 0x22 { inString = true }
            }
            i = next
        }
        return out
    }

    public func modificationDate(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path))?[.modificationDate] as? Date
    }
}
