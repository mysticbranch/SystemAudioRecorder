import Foundation

public enum ExportPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact, balanced, highQuality, wav, appleLossless, flac
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .compact: "Compact · AAC 128 kbps"
        case .balanced: "Balanced · AAC 192 kbps"
        case .highQuality: "High quality · AAC 256 kbps"
        case .wav: "WAV · 24-bit PCM"
        case .appleLossless: "Apple Lossless · 24-bit"
        case .flac: "FLAC · 24-bit"
        }
    }
    public var container: AudioContainer { self == .wav ? .wav : self == .flac ? .flac : .m4a }
    public var codec: AudioCodec { self == .wav ? .pcm : self == .flac ? .flac : self == .appleLossless ? .alac : .aac }
    public var bitrate: UInt32? { self == .compact ? 128_000 : self == .balanced ? 192_000 : self == .highQuality ? 256_000 : nil }
    public var fileExtension: String { container.fileExtension }
    public func estimatedBytes(seconds: Double) throws -> Int64 {
        let bytes = seconds * (bitrate.map { Double($0) / 8 * 1.3 } ?? 48_000 * 2 * 3) + 1_048_576
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { throw RecorderFailure("The export is too large.") }
        return Int64(bytes.rounded(.up))
    }
    public static func fromStored(_ id: String?) -> ExportPreset? {
        if id == nil || id == "aac-stereo-48000" { return .balanced }
        return id.flatMap(ExportPreset.init(rawValue:))
    }
}

public enum AudioTimeInput {
    public static func seconds(_ text: String) throws -> Double {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { throw RecorderFailure("Use seconds, mm:ss, or hh:mm:ss, with an optional decimal fraction.") }
        var total: Double = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(part), value.isFinite, value >= 0,
                  (index == parts.count - 1 || !part.contains(".")),
                  (index == 0 || value < 60) else { throw RecorderFailure("Enter a valid nonnegative audio time.") }
            total = total * 60 + value
        }
        guard total.isFinite, total < Double(Int64.max) / 192_000 else { throw RecorderFailure("The audio time is too large.") }
        return total
    }
}

public struct AudioFrameRange: Codable, Equatable, Sendable {
    public let start: Int64
    public let end: Int64
    public let sampleRate: Double
    public var duration: Double { Double(end - start) / sampleRate }
    public init(startSeconds: Double, endSeconds: Double, sampleRate: Double, totalFrames: Int64, minimumDuration: Double = 0.25) throws {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds,
              sampleRate.isFinite, (8_000...192_000).contains(sampleRate), totalFrames > 0,
              endSeconds <= Double(totalFrames) / sampleRate + 1e-9,
              endSeconds - startSeconds >= minimumDuration else { throw RecorderFailure("Select at least 0.25 seconds within the recording, with Start before End.") }
        let first = (startSeconds * sampleRate).rounded(.down), last = (endSeconds * sampleRate).rounded(.up)
        guard first < Double(Int64.max), last < Double(Int64.max) else { throw RecorderFailure("The selected range is too large.") }
        start = Int64(first); end = min(totalFrames, Int64(last)); self.sampleRate = sampleRate
    }
    public func validate(totalFrames: Int64, sourceRate: Double) throws {
        guard start >= 0, end > start, end <= totalFrames, sampleRate.isFinite,
              (8_000...192_000).contains(sampleRate), sampleRate == sourceRate else { throw RecorderFailure("The source range is invalid or its format changed.") }
    }
}

public struct AudioProcessingOptions: Codable, Equatable, Sendable {
    public enum Target: String, CaseIterable, Codable, Sendable { case entireRecording, microphoneOnly }
    public var target: Target
    public var reduceRumble: Bool
    public var reduceSpeechNoise: Bool
    public var normalizeSpeech: Bool
    public var isEnabled: Bool { reduceRumble || reduceSpeechNoise || normalizeSpeech }
    public init(target: Target = .entireRecording, reduceRumble: Bool = false, reduceSpeechNoise: Bool = false, normalizeSpeech: Bool = false) {
        self.target = target; self.reduceRumble = reduceRumble; self.reduceSpeechNoise = reduceSpeechNoise; self.normalizeSpeech = normalizeSpeech
    }
}

public enum RenderPurpose: String, Codable, Sendable { case primary, additional, clip, cleanedCopy, preview }
public struct RenderRequest: Codable, Sendable {
    public let sessionID: UUID
    public let preset: ExportPreset
    public let purpose: RenderPurpose
    public let range: AudioFrameRange?
    public let processing: AudioProcessingOptions
    public let title: String?
    public init(sessionID: UUID, preset: ExportPreset = .balanced, purpose: RenderPurpose = .additional,
                range: AudioFrameRange? = nil, processing: AudioProcessingOptions = .init(), title: String? = nil) {
        self.sessionID = sessionID; self.preset = preset; self.purpose = purpose; self.range = range; self.processing = processing; self.title = title
    }
}

public struct RenderProvenance: Codable, Equatable, Sendable {
    public var preset: ExportPreset
    public var sourceWasLossy: Bool
    public var processing: AudioProcessingOptions
    public var appliedGain: Float
    public var denoiserPreGain: Float
    public var processorVersion: String?
    public init(preset: ExportPreset, sourceWasLossy: Bool, processing: AudioProcessingOptions, appliedGain: Float, denoiserPreGain: Float = 1, processorVersion: String? = nil) {
        self.preset = preset; self.sourceWasLossy = sourceWasLossy; self.processing = processing
        self.appliedGain = appliedGain; self.denoiserPreGain = denoiserPreGain; self.processorVersion = processorVersion
    }
}
public struct AudioDerivation: Codable, Equatable, Sendable {
    public let parentSessionID: UUID
    public let parentAssetID: UUID?
    public let range: AudioFrameRange
    public init(parentSessionID: UUID, parentAssetID: UUID?, range: AudioFrameRange) {
        self.parentSessionID = parentSessionID; self.parentAssetID = parentAssetID; self.range = range
    }
}
