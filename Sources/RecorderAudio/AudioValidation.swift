import AudioToolbox
import AVFoundation
import RecorderCore

struct AudioValidation {
    let frames: Int64
    let peak: Float
    var duration: Double { Double(frames) / 48_000 }
    static func inspect(_ url: URL, preset: ExportPreset, expectedDuration: Double, check: () throws -> Void = {}) throws -> AudioValidation {
        var container: AudioFileID?
        try audioCheck(AudioFileOpenURL(url as CFURL, .readPermission, 0, &container), "Opening the output container")
        guard let container else { throw RecorderFailure("The output container could not be read.") }
        defer { AudioFileClose(container) }
        var type: AudioFileTypeID = 0, size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        try audioCheck(AudioFileGetProperty(container, kAudioFilePropertyFileFormat, &size, &type), "Checking the output container")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat, encoded = file.fileFormat.streamDescription.pointee
        let tolerance = preset.codec == .aac ? 0.1 : 1.01 / 48_000
        guard type == preset.fileType, encoded.mFormatID == preset.formatID,
              format.channelCount == 2, format.sampleRate == 48_000, file.length > 0,
              abs(Double(file.length) / 48_000 - expectedDuration) <= tolerance else { throw RecorderFailure("The saved file does not match the requested codec, format, or duration.") }
        if preset == .wav || preset == .flac {
            var depth: Int32 = 0, depthSize = UInt32(MemoryLayout<Int32>.size)
            try audioCheck(AudioFileGetProperty(container, kAudioFilePropertySourceBitDepth, &depthSize, &depth), "Checking lossless sample precision")
            guard depth == 24 else { throw RecorderFailure("The lossless output is not 24-bit audio (\(depth) bits).") }
        }
        if preset == .appleLossless {
            guard encoded.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData else { throw RecorderFailure("The ALAC output is not 24-bit audio.") }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw RecorderFailure("Could not allocate validation buffers.") }
        var peak: Float = 0
        while file.framePosition < file.length {
            try check()
            let expected = UInt32(min(4096, file.length - file.framePosition))
            try file.read(into: buffer, frameCount: expected)
            guard buffer.frameLength == expected else { throw RecorderFailure("The saved recording is truncated.") }
            for channel in 0..<2 { for frame in 0..<Int(expected) {
                let sample = buffer.floatChannelData![channel][frame]
                guard sample.isFinite else { throw RecorderFailure("The saved recording contains invalid samples.") }
                peak = max(peak, abs(sample))
            } }
        }
        return AudioValidation(frames: file.length, peak: peak)
    }
}

public struct ExportCapability: Sendable {
    public let preset: ExportPreset
    public let unavailableReason: String?
    public var isAvailable: Bool { unavailableReason == nil }
}

public enum ExportCapabilities {
    public static let cached: [ExportCapability] = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-codecs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        return probe(in: folder)
    }()
    /// Called off MainActor once at launch. Probes never request live input permissions.
    public static func probe(in folder: URL) -> [ExportCapability] {
        var size: UInt32 = 0
        let status = AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size)
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let queryStatus = status == noErr ? AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, &ids) : status
        return ExportPreset.allCases.map { preset in
            let url = folder.appendingPathComponent("codec-probe-\(UUID().uuidString).\(preset.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try audioCheck(queryStatus, "Querying audio encoders")
                guard ids.contains(preset.formatID) else { throw RecorderFailure("This macOS installation does not advertise this encoder.") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let writer = try AudioFileWriter(url: url, sampleRate: 48_000, channels: 2, preset: preset)
                let samples = (0..<4800).flatMap { i -> [Float] in let value = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.2; return [value, -value] }
                try samples.withUnsafeBufferPointer { try writer.write($0.baseAddress!, frames: 4800) }; try writer.close()
                _ = try AudioValidation.inspect(url, preset: preset, expectedDuration: 0.1)
                return ExportCapability(preset: preset, unavailableReason: nil)
            } catch { return ExportCapability(preset: preset, unavailableReason: error.localizedDescription) }
        }
    }
}
