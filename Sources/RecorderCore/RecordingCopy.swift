import Foundation

public enum RecordingCopy {
    /// Work on a sibling temporary file so a failed copy cannot replace an existing recording.
    /// Call off the main actor; large recordings may take time to copy.
    public static func save(source: URL, destination: URL) throws {
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".recording-copy-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try AudioFileDigest.copyAndSync(source: source, temporary: temporary)
        guard try AudioFileDigest.sha256(source) == AudioFileDigest.sha256(temporary) else { throw RecorderFailure("The copy did not match its source. The destination is unchanged.") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}
