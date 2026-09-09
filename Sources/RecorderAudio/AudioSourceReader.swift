import AVFoundation
import RecorderCore

/// Resolves a stable recorded-frame timeline. Only two segment handles are open at once.
struct AudioSourceReader {
    struct Track { let url: URL; let frames: Int64; let channels: Int }
    struct Interval { let system: Track?; let microphone: Track?; let start: Int64; let frames: Int64 }
    let session: RecordingSession
    let sampleRate: Double
    let microphoneChannels: Int
    let intervals: [Interval]
    let totalFrames: Int64
    let sourceWasLossy: Bool
    var channels: Int { 2 + microphoneChannels }

    init(session: RecordingSession, store: SessionStore) throws {
        try session.validate()
        self.session = session
        if session.kind == .capture && session.sourceRetention == .retained {
            sampleRate = session.sampleRate; microphoneChannels = session.microphoneChannels; sourceWasLossy = false
            var end: Int64 = 0, readable: Int64 = 0, plan: [Interval] = []
            for segment in session.segments {
                guard segment.startFrame == end, segment.frames <= Int64(session.sampleRate * 35) else { throw RecorderFailure("The source timeline is inconsistent. Original files are kept.") }
                func inspect(_ microphone: Bool) throws -> Track? {
                    do {
                        let url = try store.checkedAudioURL(session, segment: segment, microphone: microphone)
                        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                        let channels = microphone ? session.microphoneChannels : 2
                        guard file.processingFormat.channelCount == channels, file.processingFormat.sampleRate == session.sampleRate,
                              file.length > 0, file.length <= Int64(session.sampleRate * 35) else { throw RecorderFailure("A source segment has an invalid format or duration.") }
                        return Track(url: url, frames: file.length, channels: channels)
                    } catch { if session.captureCompleted { throw error }; return nil }
                }
                let system = try inspect(false), microphone = try session.microphoneChannels > 0 ? inspect(true) : nil
                let available = max(system?.frames ?? 0, microphone?.frames ?? 0)
                if session.captureCompleted {
                    guard segment.finalized, system?.frames == segment.frames,
                          session.microphoneChannels == 0 || microphone?.frames == segment.frames else { throw RecorderFailure("A complete source track is missing or truncated.") }
                }
                let frames = max(segment.frames, available)
                plan.append(Interval(system: system, microphone: microphone, start: end, frames: frames))
                end += frames; readable += available
            }
            guard readable > 0 else { throw RecorderFailure("No readable source audio was found. Original files are kept.") }
            intervals = plan; totalFrames = end
        } else {
            let url = try store.primaryAssetURL(session)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length > 0, file.processingFormat.channelCount == 2,
                  (8_000...192_000).contains(file.processingFormat.sampleRate) else { throw RecorderFailure("The saved audio has an unsupported format.") }
            sampleRate = file.processingFormat.sampleRate; microphoneChannels = 0; totalFrames = file.length
            sourceWasLossy = session.primaryAsset?.codec == .aac || session.primaryAsset?.provenance?.sourceWasLossy == true
            intervals = [Interval(system: Track(url: url, frames: file.length, channels: 2), microphone: nil, start: 0, frames: file.length)]
        }
    }

    func fullRange() throws -> AudioFrameRange {
        try AudioFrameRange(startSeconds: 0, endSeconds: Double(totalFrames) / sampleRate, sampleRate: sampleRate, totalFrames: totalFrames, minimumDuration: 0)
    }

    func visit(range: AudioFrameRange, check: () throws -> Void, consume: ([Float], Int) throws -> Void) throws {
        try range.validate(totalFrames: totalFrames, sourceRate: sampleRate)
        for interval in intervals {
            try check()
            let start = max(range.start, interval.start), end = min(range.end, interval.start + interval.frames)
            if start >= end { continue }
            let system = try interval.system.map { try AVAudioFile(forReading: $0.url, commonFormat: .pcmFormatFloat32, interleaved: false) }
            let microphone = try interval.microphone.map { try AVAudioFile(forReading: $0.url, commonFormat: .pcmFormatFloat32, interleaved: false) }
            system?.framePosition = min(system?.length ?? 0, start - interval.start)
            microphone?.framePosition = min(microphone?.length ?? 0, start - interval.start)
            var cursor = start
            while cursor < end {
                try check()
                let count = Int(min(4096, end - cursor))
                func read(_ file: AVAudioFile?) throws -> AVAudioPCMBuffer? {
                    guard let file else { return nil }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count)) else { throw RecorderFailure("Could not allocate audio buffers.") }
                    let frames = UInt32(min(Int64(count), file.length - file.framePosition))
                    if frames > 0 { try file.read(into: buffer, frameCount: frames) }
                    guard buffer.frameLength == frames else { throw RecorderFailure("A source read ended unexpectedly.") }
                    return buffer
                }
                let sys = try read(system), mic = try read(microphone)
                var block = [Float](repeating: 0, count: count * channels)
                for frame in 0..<count {
                    for channel in 0..<2 where frame < Int(sys?.frameLength ?? 0) { block[frame * channels + channel] = sys!.floatChannelData![channel][frame] }
                    for channel in 0..<microphoneChannels where frame < Int(mic?.frameLength ?? 0) { block[frame * channels + 2 + channel] = mic!.floatChannelData![channel][frame] }
                }
                guard block.allSatisfy(\.isFinite) else { throw RecorderFailure("A source contains nonfinite audio.") }
                // Recovery's one surviving track keeps its level; mixing two tracks halves each.
                if microphoneChannels > 0, (system == nil || microphone == nil) {
                    for i in block.indices { block[i] *= 2 }
                }
                try consume(block, count); cursor += Int64(count)
            }
        }
    }
}
