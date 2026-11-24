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
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url(name), options: .atomic)
    }

    public func modificationDate(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path))?[.modificationDate] as? Date
    }
}
