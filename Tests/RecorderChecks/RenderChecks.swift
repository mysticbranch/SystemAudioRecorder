import AVFoundation
import CryptoKit
import Foundation
import RecorderCore
@testable import RecorderAudio

extension RecorderChecks {
    static func renderChecks() async {
        await check("Microphone-only denoising preserves system alignment and short-frame tails") {
            for frames in [137, 480, 481, 48_137] {
                let store = try newStore()
                let input = store.root.appendingPathComponent("three-channel.caf")
                let output = store.root.appendingPathComponent("processed.caf")
                let writer = try AudioFileWriter(url: input, sampleRate: 48_000, channels: 3)
                var samples = [Float](repeating: 0, count: frames * 3)
                for frame in 0..<frames {
                    samples[frame * 3] = Float(sin(Double(frame) * 0.1)) * 0.2
                    samples[frame * 3 + 1] = Float(cos(Double(frame) * 0.07)) * 0.1
                }
                try samples.withUnsafeBufferPointer { try writer.write($0.baseAddress!, frames: UInt32(frames)) }; try writer.close()
                _ = try AudioProcessor.process(input: input, output: output, microphoneChannels: 1,
                    options: AudioProcessingOptions(target: .microphoneOnly, reduceSpeechNoise: true), preGain: 1, check: {})
                let file = try AVAudioFile(forReading: output)
                try expect(file.length == frames, "RNNoise lost short input or final partial frames")
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(frames))!
                try file.read(into: buffer)
                for frame in 0..<frames { for channel in 0..<2 {
                    try expect(abs(buffer.floatChannelData![channel][frame] - samples[frame * 3 + channel] * 0.5) < 1e-6, "Mic cleanup delayed or altered the untouched system track")
                } }
            }
        }
        await check("Cancelled derived processing preserves parent and removes only uncommitted job artifacts") {
            let store = try newStore(), raw = try fixture(store)
            let parent = try await AudioExporter(store: store).export(raw) { _ in }
            let original = try AudioFileDigest.sha256(store.primaryAssetURL(parent))
            let task = Task { try await AudioRenderService(store: store).render(RenderRequest(sessionID: parent.id, preset: .wav, purpose: .cleanedCopy,
                processing: AudioProcessingOptions(reduceSpeechNoise: true), title: "Cancelled")) }
            task.cancel()
            do { _ = try await task.value; throw CheckFailure(description: "Cancelled render succeeded") }
            catch is CancellationError {} catch { throw error }
            try expect(try store.list().sessions.count == 1 && AudioFileDigest.sha256(store.primaryAssetURL(parent)) == original, "Cancellation altered the source or left an empty derived entry")
            let previews = store.root.appendingPathComponent(".previews")
            let outside = try newStore().root
            try FileManager.default.createSymbolicLink(at: previews, withDestinationURL: outside)
            try expectFailure { _ = try store.createPreviewDirectory() }
            try expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Preview followed an intermediate symlink")
        }
        await check("Interrupted clip processing resumes the same entry and settings without duplicate assets") {
            let store = try newStore(), raw = try fixture(store)
            let parent = try await AudioExporter(store: store).export(raw) { _ in }
            let range = try AudioFrameRange(startSeconds: 0.25, endSeconds: 0.75, sampleRate: 48_000, totalFrames: 48_000)
            let request = RenderRequest(sessionID: parent.id, preset: .flac, purpose: .clip, range: range, title: "Recovered clip")
            let owner = try store.createDerived(parent: parent, kind: .clip, title: "Recovered clip", range: range)
            var job = PendingRenderJob(ownerID: owner.id, request: request)
            job.temporaryName = "export-\(UUID().uuidString).flac"
            try store.savePendingRender(job)
            let work = store.directory(for: owner.id).appendingPathComponent(job.workName)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            try Data("unfinished".utf8).write(to: work.appendingPathComponent("source.caf"))
            let temporary = store.directory(for: owner.id).appendingPathComponent(job.temporaryName!)
            try Data("unfinished".utf8).write(to: temporary)
            try expect(try store.librarySnapshot().pendingExports.contains(owner.id), "Unfinished render was not offered for recovery")
            let saved = try await AudioExporter(store: store).export(owner) { _ in }
            try expect(saved.id == owner.id && saved.assets.count == 1 && saved.primaryAsset?.codec == .flac && saved.primaryAsset?.decodedFrameCount == 24_000, "Recovery changed identity, range, or format")
            try expect(try store.list().sessions.count == 2 && store.pendingRender(owner.id) == nil, "Recovery duplicated a recording or left stale intent")
            try expect(!FileManager.default.fileExists(atPath: work.path) && !FileManager.default.fileExists(atPath: temporary.path), "Recovery left owned intermediates")
        }
        await check("Interrupted additional export preserves primary and malformed render paths are rejected") {
            let store = try newStore(), raw = try fixture(store)
            let parent = try await AudioExporter(store: store).export(raw) { _ in }
            let request = RenderRequest(sessionID: parent.id, preset: .appleLossless, purpose: .additional)
            let job = PendingRenderJob(ownerID: parent.id, request: request)
            try store.savePendingRender(job)
            let saved = try await AudioExporter(store: store).export(parent) { _ in }
            try expect(saved.primaryAssetID == parent.primaryAssetID && saved.assets.count == 2 && saved.assets.last?.codec == .alac && saved.status == parent.status, "Additional recovery replaced primary or status")
            let bad = PendingRenderJob(ownerID: parent.id, request: request, workName: "../source.caf")
            try expectFailure { try store.savePendingRender(bad) }
        }
        await check("Each advertised preset writes and fully decodes its actual codec and precision") {
            let store = try newStore()
            let capabilities = ExportCapabilities.probe(in: store.root.appendingPathComponent("probes"))
            for capability in capabilities { print("CODEC \(capability.preset.rawValue): \(capability.unavailableReason ?? "available")") }
            try expect(capabilities.allSatisfy(\.isAvailable), "A requested native format failed its smoke probe on this Mac")
            let source = try fixture(store, opposite: true)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            let primary = saved.primaryAssetID
            for preset in ExportPreset.allCases {
                let result = try await AudioRenderService(store: store).render(RenderRequest(sessionID: saved.id, preset: preset))
                let validation = try AudioValidation.inspect(result.url, preset: preset, expectedDuration: 1)
                try expect(validation.peak > 0.1 && validation.peak < 0.99 && result.session?.primaryAssetID == primary, "Additional export changed primary or lost audible content")
                let file = try AVAudioFile(forReading: result.url)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
                try file.read(into: buffer)
                let frame = min(100, Int(buffer.frameLength) - 1)
                try expect(abs(buffer.floatChannelData![0][frame] - buffer.floatChannelData![1][frame]) > 0.01, "Format export collapsed stereo")
            }
        }
        await check("Trim time and frame ranges reject malformed or unsafe values") {
            try expect(try AudioTimeInput.seconds("1:02:03.5") == 3723.5, "Time parsing failed")
            for value in ["nan", "inf", "1e30", "-1", "1:60", "1::2", "1.5:02", "1,5"] { try expectFailure { _ = try AudioTimeInput.seconds(value) } }
            for pair in [(0.0, 0.1), (1.0, 1.0), (2.0, 1.0), (-1.0, 1.0), (0.0, 4.0)] {
                try expectFailure { _ = try AudioFrameRange(startSeconds: pair.0, endSeconds: pair.1, sampleRate: 48_000, totalFrames: 144_000) }
            }
            let range = try AudioFrameRange(startSeconds: 0.10001, endSeconds: 0.40001, sampleRate: 48_000, totalFrames: 48_000)
            try expect(range.start == 4800 && range.end == 19201, "Range did not use floor/ceil bounds")
        }
        await check("Cross-segment clips at 16k, 44.1k and 48k remain independent with exact PCM duration") {
            for rate in [16_000.0, 44_100.0, 48_000.0] {
                let store = try newStore(), original = try fixture(store, rate: rate, segments: 2)
                let parent = try await AudioExporter(store: store).export(original) { _ in }
                let before = try Data(contentsOf: store.directory(for: parent.id).appendingPathComponent("session.json"))
                let range = try AudioFrameRange(startSeconds: 0.75, endSeconds: 1.25, sampleRate: rate, totalFrames: Int64(rate * 2))
                let clip = try await AudioRenderService(store: store).render(RenderRequest(sessionID: parent.id, preset: .wav, purpose: .clip, range: range, title: "Middle clip"))
                try expect(clip.asset.decodedFrameCount == 24_000 && clip.session?.id != parent.id && clip.session?.kind == .clip, "Clip length/identity incorrect")
                try expect(try Data(contentsOf: store.directory(for: parent.id).appendingPathComponent("session.json")) == before, "Clip modified parent metadata")
                let destination = root.appendingPathComponent("parent-trash-\(UUID().uuidString)")
                try store.trashSession(parent.id, using: FixtureTrash(destination: destination))
                let reexport = try await AudioRenderService(store: store).render(RenderRequest(sessionID: clip.session!.id, preset: .appleLossless))
                try expect(reexport.asset.decodedFrameCount == 24_000, "Clip depended on the deleted parent")
            }
        }
        await check("Legacy AAC re-export discloses lossy provenance and retained-source damage still fails") {
            let store = try newStore(), raw = try fixture(store)
            var saved = try await AudioExporter(store: store).export(raw) { _ in }
            saved.sourceRetention = .notRetained; try store.save(saved)
            let result = try await AudioRenderService(store: store).render(RenderRequest(sessionID: saved.id, preset: .wav))
            try expect(result.asset.provenance?.sourceWasLossy == true, "Lossless export hid prior AAC compression")
            saved = try store.load(saved.id); saved.sourceRetention = .retained; try store.save(saved)
            let sourceURL = store.audioURL(saved.id, segment: 0)
            try Data("corrupt".utf8).write(to: sourceURL)
            do { _ = try await AudioRenderService(store: store).render(RenderRequest(sessionID: saved.id)); throw CheckFailure(description: "Corrupt retained source fell back to AAC") }
            catch is CheckFailure { throw CheckFailure(description: "Corrupt retained source fell back to AAC") } catch {}
        }
        await check("Rumble filter and normalization have measurable bounded behavior") {
            func response(_ frequency: Double) -> Double {
                var filter = RumbleFilter(), energy = 0.0
                for frame in 0..<48_000 {
                    let output = filter.process(Float(sin(Double(frame) * 2 * .pi * frequency / 48_000)))
                    if frame > 4800 { energy += Double(output * output) }
                }
                return energy
            }
            try expect(response(20) < response(1000) * 0.1, "Rumble filter failed frequency response")
            var silence = AudioLevelAnalysis(); try silence.add([Float](repeating: 0.00001, count: 1920))
            try expect(silence.gain(normalize: true) == 1, "Normalization boosted near-silence")
            var speech = AudioLevelAnalysis(); try speech.add([Float](repeating: 0.05, count: 1920))
            try expect(abs(speech.gain(normalize: true) - 2) < 0.001, "Fixed RMS normalization missed its target")
        }
        await check("RNNoise keeps non-frame-aligned duration and reduces stationary noise") {
            let store = try newStore()
            var source = try fixture(store)
            let count = 96_137
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!
            buffer.frameLength = UInt32(count)
            var state: UInt64 = 42, inputEnergy: Double = 0
            for frame in 0..<count {
                state = state &* 6364136223846793005 &+ 1
                let unit: Double = Double(state >> 32) / 4294967295.0
                let sample: Float = Float(unit * 2.0 - 1.0) * 0.03
                buffer.floatChannelData![0][frame] = sample; buffer.floatChannelData![1][frame] = -sample
                if frame > 24_000 { inputEnergy += Double(sample * sample) }
            }
            do {
                var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
                let file = try AVAudioFile(forWriting: store.audioURL(source.id, segment: 0), settings: settings)
                try file.write(from: buffer)
            }
            source.segments[0].frames = Int64(count); try store.save(source)
            let parent = try await AudioExporter(store: store).export(source) { _ in }
            let result = try await AudioRenderService(store: store).render(RenderRequest(sessionID: parent.id, preset: .wav, purpose: .cleanedCopy,
                processing: AudioProcessingOptions(reduceSpeechNoise: true), title: "Denoised"))
            try expect(result.asset.decodedFrameCount == Int64(count) && result.asset.provenance?.processorVersion == SpeechDenoiser.version, "Denoising truncated its partial frame or lost processor metadata")
            let file = try AVAudioFile(forReading: result.url)
            let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count))!
            try file.read(into: output)
            var energy: Double = 0
            for frame in 24_001..<count { energy += Double(output.floatChannelData![0][frame] * output.floatChannelData![0][frame]) }
            try expect(energy < inputEnergy * 0.75, "RNNoise did not reduce the stationary noise fixture")
        }
    }
}
