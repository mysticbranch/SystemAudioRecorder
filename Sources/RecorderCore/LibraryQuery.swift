import Foundation

public enum LibrarySort: String, CaseIterable, Codable, Sendable, Hashable {
    case newestFirst
    case oldestFirst
    case title
    case longestFirst
}

public struct LibraryQuery: Equatable, Sendable {
    public var searchText: String = ""
    public var favoritesOnly = false
    public var selectedTags: Set<String> = []
    public var sort: LibrarySort = .newestFirst

    public init(searchText: String = "", favoritesOnly: Bool = false, selectedTags: Set<String> = [], sort: LibrarySort = .newestFirst) {
        self.searchText = searchText
        self.favoritesOnly = favoritesOnly
        self.selectedTags = selectedTags
        self.sort = sort
    }

    public func applying(to sessions: [RecordingSession]) -> [RecordingSession] {
        let terms = LibraryRules.searchTerms(searchText)
        let tags = Set(selectedTags.map(LibraryRules.folded))
        return sessions.filter { session in
            guard !favoritesOnly || session.isFavorite else { return false }
            let sessionTags = Set(session.tags.map(LibraryRules.folded))
            guard tags.isSubset(of: sessionTags) else { return false }
            let haystack = LibraryRules.folded(([session.title] + session.tags).joined(separator: " "))
            return terms.allSatisfy(haystack.contains)
        }.sorted(by: ordering)
    }

    private func ordering(_ left: RecordingSession, _ right: RecordingSession) -> Bool {
        switch sort {
        case .newestFirst:
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        case .oldestFirst:
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        case .title:
            let comparison = LibraryRules.folded(left.title).compare(LibraryRules.folded(right.title))
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .longestFirst:
            if left.duration != right.duration { return left.duration > right.duration }
        }
        if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }
}

public struct LibrarySnapshot: Sendable {
    public let sessions: [RecordingSession]
    public let unreadable: Int
    public let managedBytes: [UUID: Int64]
    public let sourceBytes: [UUID: Int64]
    public let missingAssets: Set<UUID>
    public let pendingExports: Set<UUID>
    public let pendingDeliveries: [DeliveryJob]
    public let hasUnreadableDeliveries: Bool

    public init(sessions: [RecordingSession], unreadable: Int, managedBytes: [UUID: Int64],
                sourceBytes: [UUID: Int64] = [:], missingAssets: Set<UUID> = [], pendingExports: Set<UUID> = [],
                pendingDeliveries: [DeliveryJob] = [], hasUnreadableDeliveries: Bool = false) {
        self.sessions = sessions
        self.unreadable = unreadable
        self.managedBytes = managedBytes
        self.sourceBytes = sourceBytes; self.missingAssets = missingAssets; self.pendingExports = pendingExports
        self.pendingDeliveries = pendingDeliveries; self.hasUnreadableDeliveries = hasUnreadableDeliveries
    }
}

public enum LibraryRules {
    private static let maxNewTitleLength = 120
    private static let maxTagLength = 24
    private static let maxTags = 10

    public static func normalizedTitle(_ raw: String) throws -> String {
        guard !containsControlCharacter(raw) else { throw RecorderFailure("Recording names cannot contain line breaks or control characters.") }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maxNewTitleLength, !containsControlCharacter(title) else {
            throw RecorderFailure("Use a recording name of 1 to 120 characters without line breaks or control characters.")
        }
        return title
    }

    public static func normalizedTags(_ raw: String) throws -> [String] {
        let candidates = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !containsControlCharacter(raw) else { throw RecorderFailure("Tags cannot contain line breaks or control characters.") }
        var seen = Set<String>()
        var result: [String] = []
        for tag in candidates {
            guard tag.count <= maxTagLength, !containsControlCharacter(tag) else {
                throw RecorderFailure("Each tag must be 1 to 24 characters without line breaks or control characters.")
            }
            if seen.insert(folded(tag)).inserted { result.append(tag) }
        }
        guard result.count <= maxTags else { throw RecorderFailure("Use at most 10 tags.") }
        return result
    }

    public static func searchTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map { folded(String($0)) }.filter { !$0.isEmpty }
    }

    public static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
