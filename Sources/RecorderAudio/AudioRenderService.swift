import AVFoundation
import Foundation
import RecorderCore

public struct RenderResult: Sendable {
    public let session: RecordingSession?
    public let asset: RecordingAsset
    public let url: URL
    public let previewDirectory: URL?
}

final class RenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

public final class AudioRenderService: Sendable {
    private let store: SessionStore
    private let capacity: @Sendable () throws -> Int64
    public init(store: SessionStore, capacity: (@Sendable () throws -> Int64)? = nil) {
        self.store = store; self.capacity = capacity ?? { try store.availableBytes() }
    }
    public func render(_ request: RenderRequest, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> RenderResult {
        let cancellation = RenderCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try self.perform(request, cancellation: cancellation, progress: progress) }.value
        } onCancel: { cancellation.cancel() }
    }
    public func sourceRange(sessionID: UUID) async throws -> AudioFrameRange {
        try await Task.detached(priority: .utility) { try AudioSourceReader(session: self.store.load(sessionID), store: self.store).fullRange() }.value
    }
    private func recover(_ pending: PendingExport, cancellation: RenderCancellation) throws -> RenderResult {
        let url = try store.pendingAudioURL(pending)
        let preset = pending.asset.provenance?.preset ?? ExportPreset.allCases.first { $0.codec == pending.asset.codec } ?? .balanced
        let validation = try AudioValidation.inspect(url, preset: preset, expectedDuration: pending.asset.duration!, check: cancellation.check)
        guard validation.peak <= 0.99, abs(validation.peak - pending.asset.peak!) < 0.001,
              validation.frames == pending.asset.decodedFrameCount,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == pending.asset.byteSize else {
            throw RecorderFailure("The pending audio changed since validation. Its files have been kept for inspection.")
        }
        try cancellation.check()
        let saved = try store.finishPendingExport(pending)
        return RenderResult(session: saved, asset: pending.asset, url: try store.assetURL(saved, asset: pending.asset), previewDirectory: nil)
    }
    private func perform(_ incoming: RenderRequest, cancellation: RenderCancellation, progress: @escaping @Sendable (Double) -> Void) throws -> RenderResult {
        try cancellation.check()
        if let pending = try store.pendingExport(incoming.sessionID) {
            guard incoming.purpose == .primary else { throw RecorderFailure("Finish the pending save before creating another export.") }
            let oldJob = try store.pendingRender(incoming.sessionID)
            let result = try recover(pending, cancellation: cancellation)
            if let oldJob { try? store.cleanRenderIntermediates(oldJob) }
            progress(1); return result
        }
        let previous = try store.pendingRender(incoming.sessionID)
        guard previous == nil || incoming.purpose == .primary else { throw RecorderFailure("Finish the pending render before creating another export.") }
        let request = previous?.request ?? incoming
        let parent = try store.load(request.sessionID)
        guard request.purpose == .primary ? [.recorded, .interrupted, .exporting].contains(parent.status) : parent.status.hasExport else {
            throw RecorderFailure("Finish recording and save or recover it before editing or exporting.")
        }
        let source = try AudioSourceReader(session: parent, store: store)
        let selection = try request.range ?? source.fullRange()
        try selection.validate(totalFrames: source.totalFrames, sourceRate: source.sampleRate)
        if request.processing.target == .microphoneOnly && source.microphoneChannels == 0 { throw RecorderFailure("Separate microphone source audio is unavailable.") }
        var processingRange = selection
        if request.purpose == .preview && request.processing.isEnabled && selection.start > 0 {
            processingRange = try AudioFrameRange(startSeconds: max(0, Double(selection.start) / source.sampleRate - 1),
                endSeconds: Double(selection.end) / source.sampleRate, sampleRate: source.sampleRate, totalFrames: source.totalFrames, minimumDuration: 0)
        }
        let intermediateBytes = processingRange.duration * 48_000 * Double(source.channels * 4 + 2 * 4)
        guard intermediateBytes.isFinite, intermediateBytes < Double(Int64.max / 4) else { throw RecorderFailure("The render is too large.") }
        let needed = RecordingLimits.reserveBytes + Int64(intermediateBytes.rounded(.up)) + (try request.preset.estimatedBytes(seconds: selection.duration)) * 2
        guard try capacity() >= needed else { throw RecorderFailure("There is not enough space for the working audio and requested export. Original recordings are kept.") }
        var owner = parent
        let derived = request.purpose == .clip || request.purpose == .cleanedCopy
        let preview = request.purpose == .preview
        if let previous {
            owner = try store.load(previous.ownerID)
            try store.cleanRenderIntermediates(previous)
        } else if derived {
            owner = try store.createDerived(parent: parent, kind: request.purpose == .clip ? .clip : .cleanedCopy,
                                            title: request.title ?? "Recording copy", range: selection, request: request)
        }
        let folder = try preview ? store.createPreviewDirectory() : store.directory(for: owner.id)
        var job = PendingRenderJob(ownerID: owner.id, request: request)
        let work = folder.appendingPathComponent(job.workName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var deliveredPreview = false
        defer { if preview && !deliveredPreview { try? store.discardPreviewDirectory(folder) } }
        do {
            if !preview { try store.savePendingRender(job) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            if request.purpose == .primary { _ = try store.updateExportStatus(id: parent.id, status: .exporting) }
            let working = work.appendingPathComponent("source.caf"), processed = work.appendingPathComponent("processed.caf")
            let workingWriter = try AudioFileWriter(url: working, sampleRate: source.sampleRate, channels: UInt32(source.channels), outputSampleRate: 48_000)
            var readFrames: Int64 = 0, targetPeak: Float = 0
            try source.visit(range: processingRange, check: cancellation.check) { block, count in
                try block.withUnsafeBufferPointer { try workingWriter.write($0.baseAddress!, frames: UInt32(count)) }
                for frame in 0..<count {
                    if request.processing.target == .microphoneOnly {
                        for channel in 0..<source.microphoneChannels { targetPeak = max(targetPeak, abs(block[frame * source.channels + 2 + channel])) }
                    } else {
                        for channel in 0..<2 {
                            let system = block[frame * source.channels + channel]
                            let sample = source.microphoneChannels > 0 ? (system + block[frame * source.channels + 2 + min(channel, source.microphoneChannels - 1)]) * 0.5 : system
                            targetPeak = max(targetPeak, abs(sample))
                        }
                    }
                }
                readFrames += Int64(count); progress(0.25 * Double(readFrames) / Double(processingRange.end - processingRange.start))
            }
            try workingWriter.close(); try cancellation.check()
            let preGain: Float = request.processing.reduceSpeechNoise && targetPeak > 0.49 ? 0.49 / targetPeak : 1
            var analysis = try AudioProcessor.process(input: working, output: processed, microphoneChannels: source.microphoneChannels,
                                                     options: request.processing, preGain: preGain, check: cancellation.check)
            progress(0.5)
            var gain = analysis.gain(normalize: request.processing.normalizeSpeech)
            let skip = try RecordingLimits.frameCount(seconds: Double(selection.start - processingRange.start) / source.sampleRate, sampleRate: 48_000)
            for attempt in 0..<2 {
                try cancellation.check()
                let temporary = folder.appendingPathComponent("export-\(UUID().uuidString).\(request.preset.fileExtension)")
                if !preview { job.temporaryName = temporary.lastPathComponent; try store.savePendingRender(job) }
                var keep = false
                defer {
                    if !keep && (preview || !FileManager.default.fileExists(atPath: store.pendingExportURL(owner.id).path)) { try? FileManager.default.removeItem(at: temporary) }
                }
                let file = try AVAudioFile(forReading: processed, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.length > skip, abs(Double(file.length) / 48_000 - processingRange.duration) <= 1.01 / 48_000 else {
                    throw RecorderFailure("Resampling produced an unexpected frame count.")
                }
                file.framePosition = skip
                let writer = try AudioFileWriter(url: temporary, sampleRate: 48_000, channels: 2, preset: request.preset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw RecorderFailure("Could not allocate export buffers.") }
                while file.framePosition < file.length {
                    try cancellation.check()
                    let expected = UInt32(min(4096, file.length - file.framePosition))
                    try file.read(into: buffer, frameCount: expected)
                    guard buffer.frameLength == expected else { throw RecorderFailure("Processed audio ended unexpectedly.") }
                    var samples = [Float](repeating: 0, count: Int(expected) * 2)
                    for frame in 0..<Int(expected) { for channel in 0..<2 { samples[frame * 2 + channel] = buffer.floatChannelData![channel][frame] * gain } }
                    try samples.withUnsafeBufferPointer { try writer.write($0.baseAddress!, frames: expected) }
                    progress(0.5 + 0.35 * Double(file.framePosition) / Double(file.length))
                }
                try writer.close(); progress(0.9)
                let validation = try AudioValidation.inspect(temporary, preset: request.preset, expectedDuration: selection.duration, check: cancellation.check)
                if validation.peak > 0.99 {
                    if attempt == 0 { gain *= 0.8 / validation.peak; continue }
                    throw RecorderFailure("Encoded audio exceeded the safe peak level. Original recordings are kept.")
                }
                try cancellation.check()
                let provenance = RenderProvenance(preset: request.preset, sourceWasLossy: source.sourceWasLossy, processing: request.processing,
                    appliedGain: gain, denoiserPreGain: preGain, processorVersion: request.processing.reduceSpeechNoise ? SpeechDenoiser.version : nil)
                if preview {
                    let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    let asset = RecordingAsset(relativePath: temporary.lastPathComponent, container: request.preset.container, codec: request.preset.codec,
                        sampleRate: 48_000, channelCount: 2, decodedFrameCount: validation.frames, duration: validation.duration, peak: validation.peak,
                        byteSize: Int64(bytes), validationState: .verified, provenance: provenance)
                    keep = true; deliveredPreview = true; progress(1)
                    return RenderResult(session: nil, asset: asset, url: temporary, previewDirectory: folder)
                }
                let saved = try store.commitRendered(sessionID: owner.id, temporaryURL: temporary, preset: request.preset,
                    frames: validation.frames, peak: validation.peak, purpose: request.purpose, provenance: provenance)
                guard let asset = saved.assets.last else { throw RecorderFailure("The rendered asset was not committed.") }
                progress(1)
                return RenderResult(session: saved, asset: asset, url: try store.assetURL(saved, asset: asset), previewDirectory: nil)
            }
            throw RecorderFailure("Could not encode audio safely.")
        } catch {
            if request.purpose == .primary { _ = try? store.updateExportStatus(id: parent.id, status: parent.captureCompleted ? .recorded : .interrupted) }
            if !preview, error is CancellationError, (try? store.pendingExport(owner.id)) == nil {
                do {
                    try store.cleanRenderIntermediates(job)
                    try store.clearPendingRender(owner.id)
                    if derived { try store.discardUncommittedDerived(owner.id) }
                } catch { /* Keep the journal and original data if safe cleanup cannot finish. */ }
            } else if derived {
                // Failures with a durable request remain visible and retryable in the library.
                try? store.discardUncommittedDerived(owner.id)
            }
            throw error
        }
    }
}
