import Foundation

public enum FilenamePattern {
    public static let standard = "{date}_{time}_{title}"
    public static func expand(_ pattern: String, session: RecordingSession, timeZone: TimeZone = .current) throws -> String {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pattern.utf8.count <= 1000 else { throw RecorderFailure("Enter a filename pattern of at most 1,000 bytes.") }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.calendar = Calendar(identifier: .gregorian); date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd"; let day = date.string(from: session.createdAt)
        date.dateFormat = "HH-mm-ss"; let time = date.string(from: session.createdAt)
        let tokens = ["date": day, "time": time, "title": session.title, "id": session.id.uuidString]
        var output = "", token = "", inside = false
        for character in pattern {
            if character == "{" { guard !inside else { throw RecorderFailure("Nested filename tokens are not supported.") }; inside = true; token = "" }
            else if character == "}" {
                guard inside, let value = tokens[token] else { throw RecorderFailure("Use only {date}, {time}, {title}, and {id} tokens.") }
                output += value; inside = false
            } else if inside { token.append(character) } else { output.append(character) }
        }
        guard !inside else { throw RecorderFailure("Close every filename token with a matching brace.") }
        var safe = ""
        for character in output {
            let invalid = character == "/" || character == "\\" || character == ":" || LibraryRules.containsControlCharacter(String(character))
            if invalid { if safe.last != "-" { safe += "-" } } else { safe.append(character) }
        }
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var bounded = ""
        for character in safe { if bounded.utf8.count + String(character).utf8.count > 180 { break }; bounded.append(character) }
        return bounded.isEmpty || bounded.allSatisfy({ $0 == "-" }) ? "Recording-\(session.id.uuidString)" : bounded
    }
}

public struct DestinationSettings: Codable, Equatable, Sendable {
    public var automaticallyCopy = false
    public var bookmark: Data?
    public var displayPath = "No folder selected"
    public var pattern = FilenamePattern.standard
    public var defaultPreset: ExportPreset = .balanced
    public init() {}
}

public final class ExportDestinationStore: @unchecked Sendable {
    private let lock = NSLock()
    public let managedRoot: URL
    private var settingsURL: URL { managedRoot.appendingPathComponent(".settings/export.json") }
    public init(managedRoot: URL) { self.managedRoot = managedRoot }
    private func checkSettingsPath() throws {
        for url in [managedRoot, settingsURL.deletingLastPathComponent(), settingsURL] where FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RecorderFailure("The export settings path is unsafe.") }
        }
    }
    public func load() throws -> DestinationSettings {
        try lock.withLock {
            try checkSettingsPath()
            guard FileManager.default.fileExists(atPath: settingsURL.path) else { return DestinationSettings() }
            let bytes = try Data(contentsOf: settingsURL)
            guard bytes.count < 1_000_000 else { throw RecorderFailure("The export settings file is too large.") }
            return try JSONDecoder().decode(DestinationSettings.self, from: bytes)
        }
    }
    public func save(_ settings: DestinationSettings) throws {
        _ = try FilenamePattern.expand(settings.pattern, session: RecordingSession())
        guard !settings.automaticallyCopy || settings.bookmark != nil else { throw RecorderFailure("Choose a folder before enabling automatic copies.") }
        try lock.withLock {
            try checkSettingsPath()
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        }
    }
    public func validateFolder(_ folder: URL) throws -> URL {
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        let root = managedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !resolved.pathComponents.starts(with: root.pathComponents) else { throw RecorderFailure("Choose a folder outside the app's managed recording storage.") }
        guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw RecorderFailure("The selected export folder is unavailable. Reconnect it or choose another folder.") }
        return resolved
    }
    public func bookmark(for folder: URL) throws -> Data {
        let folder = try validateFolder(folder)
        return try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve(_ bookmark: Data) throws -> (url: URL, refreshedBookmark: Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let resolved = try validateFolder(url)
        return (resolved, stale ? try self.bookmark(for: resolved) : nil)
    }
}
