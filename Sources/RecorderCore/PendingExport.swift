import Foundation

/// A validated primary export awaiting its short filesystem/metadata commit.
/// Kept with the owning session so Trash moves all of its internal data together.
public struct PendingExport: Codable, Sendable {
    public let sessionID: UUID
    public let asset: RecordingAsset
    public let temporaryName: String
    public var purpose: RenderPurpose? = nil

    public func validate() throws {
        try asset.validate()
        guard asset.validationState == .verified,
              purpose != .preview,
              asset.relativePath == "exports/\(asset.id.uuidString).\(asset.container.fileExtension)",
              temporaryName.hasPrefix("export-"), temporaryName.hasSuffix(".\(asset.container.fileExtension)"),
              UUID(uuidString: String(temporaryName.dropFirst(7).dropLast(asset.container.fileExtension.count + 1))) != nil else {
            throw RecorderFailure("The pending export has invalid file identities.")
        }
    }
}
