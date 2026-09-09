import Foundation

/// Moves only an already validated, app-managed session directory to the macOS Trash.
public protocol TrashService: Sendable {
    func trash(_ directory: URL) throws
}

public struct FoundationTrashService: TrashService {
    public init() {}

    public func trash(_ directory: URL) throws {
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
}
