import AVFoundation
import RecorderCore
import RNNoise

struct AudioLevelAnalysis {
    private(set) var peak: Float = 0
    private var energy: Double = 0, activeEnergy: Double = 0
    private var samples = 0, activeSamples: Int64 = 0
    mutating func add(_ interleaved: [Float]) throws {
        for sample in interleaved {
            guard sample.isFinite else { throw RecorderFailure("Audio processing produced a nonfinite sample.") }
            peak = max(peak, abs(sample)); energy += Double(sample) * Double(sample); samples += 1
            if samples == 960 * 2 { finishWindow() }
        }
    }
    mutating func finishWindow() {
        if samples > 0 && energy / Double(samples) >= 1e-5 { activeEnergy += energy; activeSamples += Int64(samples) }
        samples = 0; energy = 0
    }
    mutating func gain(normalize: Bool) -> Float {
        finishWindow()
        let safety = peak > 0 ? 0.8 / Double(peak) : 1
        guard normalize, activeSamples > 0, activeEnergy > 0 else { return peak > 0.8 ? Float(safety) : 1 }
        return Float(min(pow(10, 12.0 / 20), 0.1 / sqrt(activeEnergy / Double(activeSamples)), safety))
    }
}

struct RumbleFilter {
    private var previousInput: Double = 0, previousOutput: Double = 0
    private let alpha = (1 / (2 * Double.pi * 80)) / (1 / (2 * Double.pi * 80) + 1 / 48_000)
    mutating func process(_ input: Float) -> Float {
        let output = alpha * (previousOutput + Double(input) - previousInput)
        previousInput = Double(input); previousOutput = output
        return Float(output)
    }
}

final class SpeechDenoiser {
    static let version = "RNNoise-v0.1-cdf196b1e9de"
    static var frameSize: Int { Int(recorder_denoise_frame_size()) }
    private var states: [OpaquePointer] = []
    init(channels: Int) throws {
        for _ in 0..<channels {
            guard let state = recorder_denoise_create() else {
                states.forEach(recorder_denoise_destroy); states = []
                throw RecorderFailure("The bundled speech-noise processor could not initialize.")
            }
            states.append(state)
        }
    }
    func process(_ input: [[Float]]) throws -> [[Float]] {
        guard input.count == states.count, input.allSatisfy({ $0.count == Self.frameSize }) else { throw RecorderFailure("Invalid speech processor frame.") }
        return try input.enumerated().map { channel, samples in
            let scaled = samples.map { $0 * 32768 }
            guard scaled.allSatisfy(\.isFinite) else { throw RecorderFailure("Invalid speech processor input.") }
            var output = [Float](repeating: 0, count: Self.frameSize)
            scaled.withUnsafeBufferPointer { source in output.withUnsafeMutableBufferPointer { target in
                recorder_denoise_process(states[channel], target.baseAddress!, source.baseAddress!)
            } }
            guard output.allSatisfy(\.isFinite) else { throw RecorderFailure("The speech processor returned invalid audio.") }
            return output.map { $0 / 32768 }
        }
    }
    deinit { states.forEach(recorder_denoise_destroy) }
}

enum AudioProcessor {
    /// Uses fixed-size blocks and one delayed source block when RNNoise is enabled.
    /// The pinned 960-sample overlap-add window emits the preceding 480-sample frame.
    /// Drop its initial delayed frame, flush one zero frame, and emit exactly the input length.
    static func process(input: URL, output: URL, microphoneChannels: Int, options: AudioProcessingOptions,
                        preGain: Float, check: () throws -> Void) throws -> AudioLevelAnalysis {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let micOnly = options.target == .microphoneOnly
        guard !micOnly || microphoneChannels > 0 else { throw RecorderFailure("Separate microphone audio is unavailable for this recording.") }
        let targetChannels = micOnly ? microphoneChannels : 2
        let blockSize = options.reduceSpeechNoise ? SpeechDenoiser.frameSize : 4096
        let denoiser = try options.reduceSpeechNoise ? SpeechDenoiser(channels: targetChannels) : nil
        var filters = [RumbleFilter](repeating: RumbleFilter(), count: targetChannels)
        let writer = try AudioFileWriter(url: output, sampleRate: 48_000, channels: 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: UInt32(blockSize)) else { throw RecorderFailure("Could not allocate processing buffers.") }
        var analysis = AudioLevelAnalysis()
        var pending: ([[Float]], Int)?
        func mix(_ raw: [[Float]], _ processed: [[Float]], _ count: Int) throws {
            var mixed = [Float](repeating: 0, count: count * 2)
            for frame in 0..<count { for channel in 0..<2 {
                mixed[frame * 2 + channel] = micOnly ? (raw[channel][frame] + processed[min(channel, microphoneChannels - 1)][frame]) * 0.5 : processed[channel][frame]
            } }
            try analysis.add(mixed)
            try mixed.withUnsafeBufferPointer { try writer.write($0.baseAddress!, frames: UInt32(count)) }
        }
        while source.framePosition < source.length {
            try check()
            let count = Int(min(Int64(blockSize), source.length - source.framePosition))
            try source.read(into: buffer, frameCount: UInt32(count))
            guard buffer.frameLength == count else { throw RecorderFailure("The intermediate audio is truncated.") }
            var raw = [[Float]](repeating: [Float](repeating: 0, count: blockSize), count: 2 + microphoneChannels)
            for channel in raw.indices { for frame in 0..<count { raw[channel][frame] = buffer.floatChannelData![channel][frame] } }
            var target = [[Float]](repeating: [Float](repeating: 0, count: blockSize), count: targetChannels)
            for channel in 0..<targetChannels { for frame in 0..<count {
                var sample = micOnly ? raw[2 + channel][frame] : microphoneChannels > 0 ? (raw[channel][frame] + raw[2 + min(channel, microphoneChannels - 1)][frame]) * 0.5 : raw[channel][frame]
                if options.reduceRumble { sample = filters[channel].process(sample) }
                target[channel][frame] = sample * preGain
            } }
            if let denoiser {
                let processed = try denoiser.process(target)
                if let pending { try mix(pending.0, processed, pending.1) }
                pending = (raw, count)
            } else { try mix(raw, target, count) }
        }
        if let pending, let denoiser {
            try check()
            let tail = try denoiser.process([[Float]](repeating: [Float](repeating: 0, count: blockSize), count: targetChannels))
            try mix(pending.0, tail, pending.1)
        }
        try writer.close()
        return analysis
    }
}
