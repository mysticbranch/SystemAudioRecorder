import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case preparing, recording, pausing, paused, resuming, recorded, interrupted, exporting, ready, partial, pendingRender
    public var label: String {
        switch self {
        case .preparing: "Preparing"
        case .recording: "Recording"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .resuming: "Resuming"
        case .pendingRender: "Unfinished render"
        case .recorded: "Ready to save"
        case .interrupted: "Recovery available"
        case .exporting: "Saving"
        case .ready: "Saved"
        case .partial: "Partial recording"
        }
    }
    public var hasExport: Bool { self == .ready || self == .partial }
}

public enum RecordingKind: String, Codable, Sendable { case capture, clip, cleanedCopy }
public enum SourceRetention: String, Codable, Sendable { case retained, notRetained, notApplicable }
public enum AssetValidationState: String, Codable, Sendable { case verified, legacyNeedsValidation }
public enum AudioContainer: String, Codable, Sendable {
    case m4a, wav, flac
    public var fileExtension: String { rawValue }
}
public enum AudioCodec: String, Codable, Sendable { case aac, alac, pcm, flac }

public struct RecordingAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var relativePath: String
    public var container: AudioContainer
    public var codec: AudioCodec
    public var sampleRate: Double
    public var channelCount: Int
    public var decodedFrameCount: Int64?
    public var duration: Double?
    public var peak: Float?
    public var byteSize: Int64?
    public let createdAt: Date
    public var validationState: AssetValidationState
    public var provenance: RenderProvenance?

    public init(id: UUID = UUID(), relativePath: String, container: AudioContainer, codec: AudioCodec,
                sampleRate: Double, channelCount: Int, decodedFrameCount: Int64? = nil,
                duration: Double? = nil, peak: Float? = nil, byteSize: Int64? = nil,
                createdAt: Date = Date(), validationState: AssetValidationState, provenance: RenderProvenance? = nil) {
        self.id = id; self.relativePath = relativePath; self.container = container; self.codec = codec
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.decodedFrameCount = decodedFrameCount
        self.duration = duration; self.peak = peak; self.byteSize = byteSize; self.createdAt = createdAt
        self.validationState = validationState
        self.provenance = provenance
    }

    public func validate() throws {
        guard RecordingPath.isSafeRelativePath(relativePath),
              URL(fileURLWithPath: relativePath).pathExtension.lowercased() == container.fileExtension,
              sampleRate.isFinite, (8_000...192_000).contains(sampleRate), (1...8).contains(channelCount),
              decodedFrameCount == nil || decodedFrameCount! >= 0,
              duration == nil || (duration!.isFinite && duration! >= 0),
              peak == nil || (peak!.isFinite && peak! >= 0),
              byteSize == nil || byteSize! >= 0 else {
            throw RecorderFailure("The recording contains invalid saved-audio metadata.")
        }
        if let decodedFrameCount, let duration {
            guard abs(Double(decodedFrameCount) / sampleRate - duration) <= 0.1 else {
                throw RecorderFailure("The saved recording duration does not match its frame count.")
            }
        }
        let validCodec = (container == .m4a && [.aac, .alac].contains(codec)) ||
            (container == .wav && codec == .pcm) || (container == .flac && codec == .flac)
        guard validCodec else { throw RecorderFailure("The saved-audio codec does not match its container.") }
        if let provenance {
            guard provenance.preset.codec == codec, provenance.preset.container == container,
                  provenance.appliedGain.isFinite, provenance.appliedGain > 0, provenance.appliedGain <= 4,
                  provenance.denoiserPreGain.isFinite, provenance.denoiserPreGain > 0, provenance.denoiserPreGain <= 1,
                  provenance.processorVersion.map({ $0.count <= 200 }) ?? true else {
                throw RecorderFailure("The saved audio has invalid processing metadata.")
            }
        }
        if validationState == .verified {
            guard let decodedFrameCount, decodedFrameCount > 0, let duration, duration > 0,
                  peak != nil, let byteSize, byteSize > 0 else {
                throw RecorderFailure("Verified audio must include its measured frames, duration, peak, and file size.")
            }
        }
    }
}

public struct RecordingSegment: Codable, Equatable, Sendable {
    public let index: Int
    public let startFrame: Int64
    public var frames: Int64
    public var finalized: Bool
    public init(index: Int, startFrame: Int64, frames: Int64 = 0, finalized: Bool = false) {
        self.index = index; self.startFrame = startFrame
        self.frames = frames; self.finalized = finalized
    }
}

public struct RecordingSession: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public var title: String
    public var status: SessionStatus
    public var sampleRate: Double
    public var microphoneChannels: Int
    public var segments: [RecordingSegment]
    public var captureCompleted: Bool
    public var issue: String?
    public var kind: RecordingKind
    public var sourceRetention: SourceRetention
    public var tags: [String]
    public var isFavorite: Bool
    public var assets: [RecordingAsset]
    public var primaryAssetID: UUID?
    public var captureExportPresetID: String?
    public var derivation: AudioDerivation?

    public init(id: UUID = UUID(), createdAt: Date = Date(), title: String? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.createdAt = createdAt
        self.title = title ?? Self.defaultTitle(for: createdAt)
        status = .preparing; sampleRate = 48_000; microphoneChannels = 0
        segments = []; captureCompleted = false; issue = nil
        kind = .capture; sourceRetention = .retained
        tags = []; isFavorite = false; assets = []; primaryAssetID = nil; captureExportPresetID = "aac-stereo-48000"
    }

    public var primaryAsset: RecordingAsset? {
        guard let primaryAssetID else { return nil }
        return assets.first { $0.id == primaryAssetID }
    }
    public var duration: Double {
        primaryAsset?.duration ?? Double(segments.map { $0.startFrame + $0.frames }.max() ?? 0) / sampleRate
    }
    // Compatibility for existing callers. New metadata stores these values on its primary asset.
    public var exportedDuration: Double? { primaryAsset?.duration }
    public var exportedPeak: Float? { primaryAsset?.peak }
    public var canExport: Bool { [.recorded, .interrupted].contains(status) && !segments.isEmpty }

    public static func defaultTitle(for date: Date) -> String {
        "Recording \(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion, sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (0...2).contains(microphoneChannels), segments.count <= 100_000,
              title.count <= 500, !title.isEmpty, !LibraryRules.containsControlCharacter(title), tags.count <= 10 else {
            throw RecorderFailure("The recording metadata is not supported.")
        }
        var normalizedTags = Set<String>()
        for tag in tags {
            guard !tag.isEmpty, tag.count <= 24, !LibraryRules.containsControlCharacter(tag),
                  normalizedTags.insert(LibraryRules.folded(tag)).inserted else {
                throw RecorderFailure("The recording tags are not supported.")
            }
        }
        var previousEnd: Int64 = 0
        var indices = Set<Int>()
        for segment in segments {
            guard (0..<100_000).contains(segment.index), indices.insert(segment.index).inserted,
                  segment.startFrame >= previousEnd, segment.frames >= 0,
                  segment.startFrame < Int64.max / 2, segment.frames < Int64.max / 2 else {
                throw RecorderFailure("The recording contains invalid segment metadata.")
            }
            previousEnd = segment.startFrame + segment.frames
        }
        guard assets.count <= 100, Set(assets.map(\.id)).count == assets.count else {
            throw RecorderFailure("The recording contains duplicate saved-audio metadata.")
        }
        try assets.forEach { try $0.validate() }
        if let primaryAssetID, !assets.contains(where: { $0.id == primaryAssetID }) {
            throw RecorderFailure("The recording's primary saved audio is missing.")
        }
        if status.hasExport && primaryAsset == nil { throw RecorderFailure("The recording has no saved audio.") }
        if kind == .capture {
            guard sourceRetention != .notApplicable else { throw RecorderFailure("A captured recording must declare its source retention.") }
        } else if sourceRetention != .notApplicable || !segments.isEmpty || captureCompleted {
            throw RecorderFailure("A derived recording cannot claim capture source files.")
        }
        if let derivation {
            guard kind != .capture, derivation.parentSessionID != id else { throw RecorderFailure("The recording has invalid parent metadata.") }
            try derivation.range.validate(totalFrames: derivation.range.end, sourceRate: derivation.range.sampleRate)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, title, status, sampleRate, microphoneChannels, segments, captureCompleted, issue
        case exportedDuration, exportedPeak, kind, sourceRetention, tags, isFavorite, assets, primaryAssetID, captureExportPresetID, derivation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == 1 || version == Self.currentSchemaVersion else {
            throw RecorderFailure("This recording was created by a newer version of System Audio Recorder.")
        }
        let id = try container.decode(UUID.self, forKey: .id)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let status = try container.decode(SessionStatus.self, forKey: .status)
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.createdAt = createdAt; self.title = try container.decode(String.self, forKey: .title)
        self.status = status; self.sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        self.microphoneChannels = try container.decode(Int.self, forKey: .microphoneChannels)
        self.segments = try container.decode([RecordingSegment].self, forKey: .segments)
        self.captureCompleted = try container.decode(Bool.self, forKey: .captureCompleted)
        self.issue = try container.decodeIfPresent(String.self, forKey: .issue)
        self.derivation = try container.decodeIfPresent(AudioDerivation.self, forKey: .derivation)
        if version == 1 {
            let duration = try container.decodeIfPresent(Double.self, forKey: .exportedDuration)
            let peak = try container.decodeIfPresent(Float.self, forKey: .exportedPeak)
            // Validate before converting: a finite JSON number can still overflow Int64.
            if let duration { _ = try RecordingLimits.frameCount(seconds: duration, sampleRate: 48_000) }
            if let peak, !peak.isFinite || peak < 0 { throw RecorderFailure("Invalid legacy audio peak.") }
            kind = .capture; sourceRetention = status == .ready ? .notRetained : .retained
            tags = []; isFavorite = false; captureExportPresetID = nil
            if status.hasExport {
                assets = [RecordingAsset(id: id, relativePath: "Recording.m4a", container: .m4a, codec: .aac,
                                         sampleRate: 48_000, channelCount: 2,
                                         decodedFrameCount: try duration.map { try RecordingLimits.frameCount(seconds: $0, sampleRate: 48_000) },
                                         duration: duration, peak: peak, validationState: .legacyNeedsValidation)]
                primaryAssetID = id
            } else { assets = []; primaryAssetID = nil }
        } else {
            kind = try container.decode(RecordingKind.self, forKey: .kind)
            sourceRetention = try container.decode(SourceRetention.self, forKey: .sourceRetention)
            tags = try container.decode([String].self, forKey: .tags)
            isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
            assets = try container.decode([RecordingAsset].self, forKey: .assets)
            primaryAssetID = try container.decodeIfPresent(UUID.self, forKey: .primaryAssetID)
            captureExportPresetID = try container.decodeIfPresent(String.self, forKey: .captureExportPresetID)
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id); try container.encode(createdAt, forKey: .createdAt)
        try container.encode(title, forKey: .title); try container.encode(status, forKey: .status)
        try container.encode(sampleRate, forKey: .sampleRate); try container.encode(microphoneChannels, forKey: .microphoneChannels)
        try container.encode(segments, forKey: .segments); try container.encode(captureCompleted, forKey: .captureCompleted)
        try container.encodeIfPresent(issue, forKey: .issue)
        try container.encode(kind, forKey: .kind); try container.encode(sourceRetention, forKey: .sourceRetention)
        try container.encode(tags, forKey: .tags); try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(assets, forKey: .assets); try container.encodeIfPresent(primaryAssetID, forKey: .primaryAssetID)
        try container.encodeIfPresent(captureExportPresetID, forKey: .captureExportPresetID)
        try container.encodeIfPresent(derivation, forKey: .derivation)
    }
}

public enum RecordingPath {
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\"),
              !LibraryRules.containsControlCharacter(path) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct RecorderFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum RecordingLimits {
    public static func frameCount(seconds: Double, sampleRate: Double) throws -> Int64 {
        let frames = (seconds * sampleRate).rounded()
        guard seconds.isFinite, seconds >= 0, sampleRate.isFinite, sampleRate > 0,
              frames.isFinite, frames >= 0, frames < Double(Int64.max) else {
            throw RecorderFailure("The recording duration is outside the supported range.")
        }
        return Int64(frames)
    }
    public static let reserveBytes: Int64 = 256 * 1_024 * 1_024
    public static func duration(minutes text: String) throws -> TimeInterval? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let minutes = Double(value.replacingOccurrences(of: ",", with: ".")), minutes.isFinite,
              minutes >= 1.0 / 60.0, minutes <= 1_440 else {
            throw RecorderFailure("Enter a duration between 1 second and 1,440 minutes, or leave it blank.")
        }
        return minutes * 60
    }
    public static func bytesPerSecond(sampleRate: Double, microphoneChannels: Int) -> Double {
        sampleRate * Double(2 + microphoneChannels) * 4
    }
    public static func hasRecordingHeadroom(available: Int64, sampleRate: Double, microphoneChannels: Int) -> Bool {
        available >= reserveBytes + Int64(bytesPerSecond(sampleRate: sampleRate, microphoneChannels: microphoneChannels) * 35)
    }
}

public enum RecorderPhase: Equatable, Sendable {
    case idle, preparing, recording, pausing, paused, resuming, stopping, exporting, failed
    public var isBusy: Bool { [.preparing, .pausing, .resuming, .stopping, .exporting].contains(self) }
    public var canStart: Bool { self == .idle || self == .failed }
    public var title: String {
        switch self {
        case .idle: "Ready when you are"
        case .preparing: "Preparing your recording"
        case .recording: "Recording"
        case .pausing: "Pausing your recording"
        case .paused: "Recording paused"
        case .resuming: "Resuming your recording"
        case .stopping: "Finishing the recording"
        case .exporting: "Saving your recording"
        case .failed: "Your attention is needed"
        }
    }
}
