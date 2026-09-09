import Foundation

/// Durable intent written before offline processing. Recovery uses the same owner and settings.
public struct PendingRenderJob: Codable, Sendable {
    public let ownerID: UUID
    public let request: RenderRequest
    public let workName: String
    public var temporaryName: String?

    public init(ownerID: UUID, request: RenderRequest, workName: String = ".work-\(UUID().uuidString)") {
        self.ownerID = ownerID; self.request = request; self.workName = workName
    }
    public func validate() throws {
        guard request.purpose != .preview, workName.hasPrefix(".work-"),
              UUID(uuidString: String(workName.dropFirst(6))) != nil else {
            throw RecorderFailure("The unfinished render has invalid ownership metadata.")
        }
        if let temporaryName {
            let suffix = "." + request.preset.fileExtension
            guard temporaryName.hasPrefix("export-"), temporaryName.hasSuffix(suffix),
                  UUID(uuidString: String(temporaryName.dropFirst(7).dropLast(suffix.count))) != nil else {
                throw RecorderFailure("The unfinished render has an unsafe temporary path.")
            }
        }
        if let range = request.range { try range.validate(totalFrames: range.end, sourceRate: range.sampleRate) }
        if request.purpose == .clip || request.purpose == .cleanedCopy {
            guard request.sessionID != ownerID else { throw RecorderFailure("A derived render cannot replace its parent.") }
            _ = try LibraryRules.normalizedTitle(request.title ?? "Recording copy")
        } else if request.sessionID != ownerID {
            throw RecorderFailure("The unfinished export belongs to another recording.")
        }
    }
}
