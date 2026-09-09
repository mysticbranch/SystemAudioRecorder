import AudioTransport
import AVFoundation
import Foundation
import RecorderCore
@testable import RecorderAudio
@testable import RecorderUI

extension RecorderChecks {
    static func pauseChecks() async {
        await check("Pause writer failures produce interrupted sessions and retain recoverable source files") {
            for failWrite in [false, true] {
                let store = try newStore(), plan = GraphPlan(frames: [480])
                let service = CaptureService(store: store, graphFactory: { options, uid in try plan.make(options, uid) },
                    writerFactory: { try FailingCaptureWriter(url: $0, rate: $1, channels: $2, failWrite: failWrite) }, capacity: { Int64.max })
                let original = try store.create()
                try await service.start(session: original, options: CaptureOptions(includeMicrophone: false)) { _ in }
                do { _ = try await service.pause(); throw CheckFailure(description: "Pause hid the writer failure") }
                catch is CheckFailure { throw CheckFailure(description: "Pause hid the writer failure") } catch {}
                let saved = try store.load(original.id)
                try expect(saved.status == .interrupted && !saved.captureCompleted && saved.issue != nil && plan.closed == 1, "Writer failure did not stop safely")
                try expect(FileManager.default.fileExists(atPath: store.audioURL(saved.id, segment: 0).path), "Writer failure deleted recoverable audio")
                if !failWrite {
                    let recovered = try await AudioExporter(store: store).export(saved) { _ in }
                    try expect(recovered.status == .partial && recovered.duration > 0, "Closed audio could not be recovered after reported close failure")
                }
            }
        }
        await check("Real capture service recreates graphs and concatenates paused intervals") {
            let store = try newStore(), plan = GraphPlan(frames: [48_000, 24_000])
            let service = CaptureService(store: store, graphFactory: { options, uid in try plan.make(options, uid) }, capacity: { Int64.max })
            let session = try store.create()
            try await service.start(session: session, options: CaptureOptions(includeMicrophone: false)) { _ in }
            let paused = try await service.pause()
            try expect(paused.recordedFrames == 48_000 && paused.session.status == .paused && plan.closed == 1, "Pause did not detach and persist 48000 frames")
            do { try await service.start(session: session, options: CaptureOptions(includeMicrophone: false)) { _ in }; throw CheckFailure(description: "Duplicate start succeeded") }
            catch is CheckFailure { throw CheckFailure(description: "Duplicate start succeeded") } catch {}
            try await Task.sleep(for: .milliseconds(150))
            _ = try await service.resume()
            let final = try await service.stop(reason: nil)
            try expect(final.captureCompleted && final.segments.map(\.startFrame) == [0, 48_000] && final.segments.map(\.frames) == [48_000, 24_000], "Pause added a gap or lost frames")
            try expect(plan.created == 2 && plan.closed == 2, "Graph ownership was not balanced")
            let saved = try await AudioExporter(store: store).export(final) { _ in }
            try expect(abs(saved.duration - 1.5) < 0.1, "Paused wall time entered the export")
        }
        await check("Capture pause handles segment boundaries, zero frames, and 100 cycles") {
            for frames in [0, 1_439_999, 1_440_000, 1_440_001] {
                let store = try newStore(), plan = GraphPlan(frames: [frames, 480])
                let service = CaptureService(store: store, graphFactory: { options, uid in try plan.make(options, uid) }, capacity: { Int64.max })
                try await service.start(session: store.create(), options: CaptureOptions(includeMicrophone: false)) { _ in }
                _ = try await service.pause(); _ = try await service.resume()
                let result = try await service.stop(reason: nil)
                try expect(result.segments.allSatisfy { $0.frames > 0 && $0.finalized } && result.segments.reduce(0, { $0 + $1.frames }) == Int64(frames + 480), "Empty tail or boundary frame loss")
            }
            let store = try newStore(), plan = GraphPlan(frames: Array(repeating: 48, count: 101))
            let service = CaptureService(store: store, graphFactory: { options, uid in try plan.make(options, uid) }, capacity: { Int64.max })
            try await service.start(session: store.create(), options: CaptureOptions(includeMicrophone: false)) { _ in }
            for _ in 0..<100 { _ = try await service.pause(); _ = try await service.resume() }
            let result = try await service.stop(reason: nil)
            try expect(plan.created == 101 && plan.closed == 101 && result.segments.count == 101, "Repeated graph lifecycle leaked ownership or segments")
        }
        await check("Captured-frame limit caps final drains across pause and resume") {
            let store = try newStore(), plan = GraphPlan(frames: [48_000, 120_000])
            let service = CaptureService(store: store, graphFactory: { options, uid in try plan.make(options, uid) }, capacity: { Int64.max })
            try await service.start(session: store.create(), options: CaptureOptions(includeMicrophone: false, maximumDuration: 3)) { _ in }
            _ = try await service.pause(); _ = try await service.resume()
            let result = try await service.stop(reason: nil)
            let repeated = try await service.stop(reason: nil)
            try expect(result.segments.reduce(0, { $0 + $1.frames }) == 144_000 && repeated == result, "Final drain exceeded captured frame budget")
        }
        await check("Incompatible resume and paused startup recovery preserve earlier source audio") {
            let store = try newStore(), plan = GraphPlan(frames: [480, 480], rates: [48_000, 44_100])
            let service = CaptureService(store: store, graphFactory: { options, uid in try plan.make(options, uid) }, capacity: { Int64.max })
            let original = try store.create()
            try await service.start(session: original, options: CaptureOptions(includeMicrophone: false)) { _ in }
            _ = try await service.pause()
            let recovered = try store.list(recoverInterrupted: true).sessions.first!
            try expect(recovered.status == .interrupted && !recovered.captureCompleted, "Paused crash was not recoverable")
            do { _ = try await service.resume(); throw CheckFailure(description: "Changed rate accepted") }
            catch is CheckFailure { throw CheckFailure(description: "Changed rate accepted") } catch {}
            let result = try store.load(original.id)
            try expect(result.status == .interrupted && result.segments.first?.frames == 480 && plan.closed == 2, "Failed resume lost source/graph ownership")
        }
        await check("UI pause locks settings and Stop during transition finalizes once") {
            let store = try newStore()
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), exporter: WaitingExporter(), preferences: EphemeralPreferences(), observeSleep: false)
            try await wait { model.canWorkWithFiles }
            model.start(); try await wait { model.phase == .recording }
            model.toggleCapturePause(); try expect(model.phase == .pausing, "Pause did not claim transition")
            try await wait { model.phase == .paused }
            try expect(!model.canWorkWithFiles && !model.phase.canStart, "Paused capture allowed another operation")
            if CommandLine.arguments.contains("--ui-snapshots") { try await snapshot(model, name: "paused-minimum", width: 620, height: 760) }
            model.toggleCapturePause(); model.stop(reason: "Test transition stop")
            try await wait { model.phase == .idle }
            await model.shutdown()
        }
    }
}

private final class FailingCaptureWriter: CaptureWriting {
    let writer: AudioFileWriter
    let failWrite: Bool
    var writtenFrames: Int64 { writer.writtenFrames }
    init(url: URL, rate: Double, channels: UInt32, failWrite: Bool) throws {
        writer = try AudioFileWriter(url: url, sampleRate: rate, channels: channels); self.failWrite = failWrite
    }
    func write(_ samples: UnsafePointer<Float>, frames: UInt32) throws {
        if failWrite { throw RecorderFailure("Injected source write failure") }
        try writer.write(samples, frames: frames)
    }
    func close() throws {
        try writer.close()
        if !failWrite { throw RecorderFailure("Injected source close failure") }
    }
}

private final class GraphPlan: @unchecked Sendable {
    let frames: [Int]
    let rates: [Double]
    private let lock = NSLock()
    private var made = 0, disposed = 0
    var created: Int { lock.withLock { made } }
    var closed: Int { lock.withLock { disposed } }
    init(frames: [Int], rates: [Double] = []) { self.frames = frames; self.rates = rates }
    func make(_ options: CaptureOptions, _ uid: String?) throws -> any CaptureGraphControlling {
        let index = lock.withLock { let index = made; made += 1; return index }
        guard frames.indices.contains(index) else { throw RecorderFailure("Unexpected graph creation") }
        return try ScriptedGraph(frames: frames[index], sampleRate: rates.isEmpty ? 48_000 : rates[index]) { self.lock.withLock { self.disposed += 1 } }
    }
}

private final class ScriptedGraph: CaptureGraphControlling {
    var transport: OpaquePointer?
    let sampleRate: Double
    let microphoneChannels = 0
    let microphoneUID: String? = nil
    let frames: Int
    let onClose: () -> Void
    init(frames: Int, sampleRate: Double, onClose: @escaping () -> Void) throws {
        self.frames = frames; self.sampleRate = sampleRate; self.onClose = onClose
        transport = recorder_transport_create(UInt32(max(4096, frames + 1)), 0, 0, 0)
        if transport == nil { throw RecorderFailure("Test ring allocation failed") }
    }
    func start() throws {
        let samples = (0..<(frames * 2)).map { i in Float(sin(Double(i / 2) * 2 * .pi * 440 / sampleRate)) * (i.isMultiple(of: 2) ? 0.2 : -0.2) }
        _ = samples.withUnsafeBufferPointer { recorder_transport_feed(transport, $0.baseAddress, nil, UInt32(frames), 0, true) }
    }
    func checkConfiguration() throws {}
    func detach() throws { if let transport { recorder_transport_stop(transport) } }
    func close() throws {
        if let transport { recorder_transport_destroy(transport); self.transport = nil; onClose() }
    }
    deinit { try? close() }
}
