import AppKit
import AVFoundation
import AudioTransport
import Foundation
import RecorderAudio
import RecorderCore
import SwiftUI
@testable import RecorderUI

struct CheckFailure: Error, CustomStringConvertible { let description: String }
private struct LegacyManifest: Codable {
    var schemaVersion: Int = 1
    let id: UUID
    let createdAt: Date
    let title: String
    let status: SessionStatus
    let sampleRate: Double
    let microphoneChannels: Int
    let segments: [RecordingSegment]
    let captureCompleted: Bool
    let issue: String?
    let exportedDuration: Double?
    let exportedPeak: Float?
}
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw CheckFailure(description: message) }
}
func expectFailure(_ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw CheckFailure(description: "Expected an error, but the operation succeeded")
}

@main
@MainActor
struct RecorderChecks {
    static var passed = 0
    static var failures: [String] = []
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-checks-\(UUID().uuidString)")

    static func check(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); passed += 1; print("PASS \(name)") }
        catch { failures.append(name); print("FAIL \(name): \(error)") }
    }
    static func newStore() throws -> SessionStore {
        try SessionStore(root: root.appendingPathComponent(UUID().uuidString))
    }
    static func makeAudio(_ url: URL, sampleRate: Double, channels: Int, seconds: Double,
                          amplitude: Float, opposite: Bool = false) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: UInt32(channels))!
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let count = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for channel in 0..<channels {
            for frame in 0..<Int(count) {
                buffer.floatChannelData![channel][frame] = amplitude * sin(Float(Double(frame) * 2 * .pi * 440 / sampleRate)) * (opposite && channel == 1 ? -1 : 1)
            }
        }
        try writer.write(from: buffer)
    }
    static func fixture(_ store: SessionStore, microphone: Bool = false, rate: Double = 48_000,
                        amplitude: Float = 0.2, opposite: Bool = false, segments: Int = 1) throws -> RecordingSession {
        var session = try store.create()
        session.sampleRate = rate; session.microphoneChannels = microphone ? 1 : 0
        session.captureCompleted = true; session.status = .recorded
        for index in 0..<segments {
            let segment = RecordingSegment(index: index, startFrame: Int64(index) * Int64(rate), frames: Int64(rate), finalized: true)
            session.segments.append(segment)
            try makeAudio(store.audioURL(session.id, segment: index), sampleRate: rate, channels: 2, seconds: 1, amplitude: amplitude, opposite: opposite)
            if microphone {
                try makeAudio(store.audioURL(session.id, segment: index, microphone: true), sampleRate: rate, channels: 1, seconds: 1, amplitude: amplitude)
            }
        }
        try store.save(session)
        return session
    }
    static func main() async {
        await check("Duration parsing and bounds") {
            try expect(try RecordingLimits.duration(minutes: " ") == nil, "Blank must mean unlimited")
            try expect(try RecordingLimits.duration(minutes: "2,5") == 150, "Comma duration")
            try expect(try RecordingLimits.duration(minutes: "1440") == 86_400, "Maximum duration")
            for invalid in ["0", "-1", "nan", "inf", "1441", "0.001", "hello"] {
                try expectFailure { _ = try RecordingLimits.duration(minutes: invalid) }
            }
        }
        await check("Session state headings and controls") {
            try expect(RecorderPhase.exporting.title != RecorderPhase.idle.title, "Export must not say ready")
            try expect(!RecorderPhase.exporting.canStart && RecorderPhase.exporting.isBusy, "Export must block another recording")
            try expect(!RecorderPhase.stopping.canStart && !RecorderPhase.preparing.canStart, "Busy transitions")
            try expect(RecorderPhase.failed.canStart, "Errors must allow retry")
        }
        await check("Format-aware disk headroom") {
            try expect(RecordingLimits.bytesPerSecond(sampleRate: 48_000, microphoneChannels: 1) == 576_000, "Raw storage estimate")
            try expect(!RecordingLimits.hasRecordingHeadroom(available: RecordingLimits.reserveBytes, sampleRate: 48_000, microphoneChannels: 1), "Reserve alone is insufficient")
        }
        await check("Persisted interrupted capture is recoverable") {
            let store = try newStore(); var session = try store.create()
            session.status = .recording; try store.save(session)
            let result = try store.list(recoverInterrupted: true)
            try expect(result.sessions.first?.status == .interrupted, "Interrupted session not recovered")
            try expect(result.sessions.first?.captureCompleted == false, "Interrupted capture marked complete")
        }
        await check("Interrupted export retries without losing capture completion") {
            let store = try newStore(); var session = try store.create()
            session.status = .exporting; session.captureCompleted = true; try store.save(session)
            try expect(try store.list(recoverInterrupted: true).sessions.first?.status == .recorded, "Export retry status")
        }
        await check("Invalid metadata and corrupt folders stay isolated") {
            let store = try newStore(); var session = try store.create()
            session.segments = [RecordingSegment(index: -1, startFrame: 0)]
            try expectFailure { try store.save(session) }
            let manifest = store.directory(for: session.id).appendingPathComponent("session.json")
            try Data("bad metadata".utf8).write(to: manifest)
            let result = try store.list()
            try expect(result.unreadable == 1 && result.sessions.isEmpty, "Unreadable session not reported")
        }
        await check("V1 manifests load without writes and migrate with an exact backup") {
            let store = try newStore(); let created = try store.create()
            let legacy = LegacyManifest(id: created.id, createdAt: created.createdAt, title: "Old meeting", status: .ready,
                                        sampleRate: 48_000, microphoneChannels: 0, segments: [], captureCompleted: true,
                                        issue: nil, exportedDuration: 12, exportedPeak: 0.4)
            let manifest = store.directory(for: created.id).appendingPathComponent("session.json")
            let original = try JSONEncoder().encode(legacy)
            try original.write(to: manifest, options: .atomic)
            let loaded = try store.load(created.id)
            try expect(loaded.schemaVersion == 2 && loaded.primaryAsset?.relativePath == "Recording.m4a", "V1 export was not mapped to an asset")
            try expect(loaded.sourceRetention == .notRetained && loaded.primaryAsset?.validationState == .legacyNeedsValidation, "V1 retention was not mapped")
            try expect(try Data(contentsOf: manifest) == original, "Loading rewrote a V1 manifest")
            let migrated = try store.updateLibraryMetadata(id: created.id, title: "Renamed meeting", tags: ["Team"], isFavorite: true)
            let backup = store.directory(for: created.id).appendingPathComponent("session-v1.backup.json")
            try expect(try Data(contentsOf: backup) == original, "V1 backup did not preserve the exact original bytes")
            try expect(migrated.schemaVersion == 2 && migrated.title == "Renamed meeting" && migrated.tags == ["Team"], "Metadata update did not migrate V1")
        }
        await check("Library query normalizes search, tags, favorites, and order") {
            var older = RecordingSession(id: UUID(), createdAt: Date(timeIntervalSince1970: 10), title: "Über meeting")
            older.tags = ["Design", "Sprint"]; older.isFavorite = true
            var newer = RecordingSession(id: UUID(), createdAt: Date(timeIntervalSince1970: 20), title: "Release notes")
            newer.tags = ["Design"]
            let query = LibraryQuery(searchText: "uber meeting", favoritesOnly: true, selectedTags: ["design"], sort: .title)
            try expect(query.applying(to: [newer, older]).map(\.id) == [older.id], "Search or folded tag filtering failed")
            try expect(try LibraryRules.normalizedTags("Design, design, DÉSIGN") == ["Design"], "Tags were not de-duplicated")
            try expectFailure { _ = try LibraryRules.normalizedTitle("bad\nname") }
        }
        await check("Metadata edits preserve retained-source and asset records") {
            let store = try newStore(); var session = try store.create()
            let asset = RecordingAsset(relativePath: "exports/test.m4a", container: .m4a, codec: .aac,
                                       sampleRate: 48_000, channelCount: 2, decodedFrameCount: 48_000, duration: 1, peak: 0.2, byteSize: 100,
                                       validationState: .verified)
            session.status = .ready; session.captureCompleted = true; session.assets = [asset]; session.primaryAssetID = asset.id
            try store.save(session)
            let saved = try store.updateLibraryMetadata(id: session.id, title: "Project review", tags: ["Work", "work"], isFavorite: true)
            try expect(saved.primaryAsset == asset && saved.sourceRetention == .retained, "Metadata edit changed audio provenance")
            try expect(saved.tags == ["Work"] && saved.isFavorite, "Metadata edit did not normalize values")
        }
        await check("Trash requests validate the exact managed session directory") {
            let store = try newStore(); let session = try store.create(); let trash = RecordingTrashService()
            try store.trashSession(session.id, using: trash)
            try expect(trash.urls == [store.directory(for: session.id)], "Trash service received the wrong directory")
            try expectFailure { try store.trashSession(UUID(), using: trash) }
            try expect(trash.urls.count == 1, "Invalid trash request reached the service")
            trash.shouldFail = true
            try expectFailure { try store.trashSession(session.id, using: trash) }
            try expect(try store.load(session.id).id == session.id, "A failed Trash action changed session data")
        }
        await check("Recording copies replace only after successful copying") {
            let folder = try newStore().root
            let source = folder.appendingPathComponent("source.m4a")
            let destination = folder.appendingPathComponent("copy.m4a")
            try Data("original".utf8).write(to: destination)
            try expectFailure { try RecordingCopy.save(source: source, destination: destination) }
            try expect(try Data(contentsOf: destination) == Data("original".utf8), "Failed copy damaged destination")
            try Data("new recording".utf8).write(to: source)
            try RecordingCopy.save(source: source, destination: destination)
            try expect(try Data(contentsOf: destination) == Data(contentsOf: source), "Copy changed content")
            try RecordingCopy.save(source: source, destination: source)
            try expect(try Data(contentsOf: source) == Data("new recording".utf8), "Self-copy damaged recording")
        }
        await check("Symbolic links cannot redirect recording reads") {
            let store = try newStore(); let session = try store.create()
            let segment = RecordingSegment(index: 0, startFrame: 0)
            try FileManager.default.createSymbolicLink(at: store.audioURL(session.id, segment: 0), withDestinationURL: store.root)
            try expectFailure { _ = try store.checkedAudioURL(session, segment: segment, microphone: false) }
        }
        await check("Transport wraps without dropping or reordering samples") {
            let ring = recorder_transport_create(7, 0, 0, 0)!
            defer { recorder_transport_destroy(ring) }
            var out = [Float](repeating: 0, count: 6)
            for iteration in 0..<1000 {
                let samples = (0..<6).map { Float(iteration * 6 + $0) }
                let count = samples.withUnsafeBufferPointer { recorder_transport_feed(ring, $0.baseAddress, nil, 3, Double(iteration * 3), true) }
                let read = out.withUnsafeMutableBufferPointer { recorder_transport_read(ring, $0.baseAddress, 3) }
                try expect(count == 3 && read == 3 && out == samples, "Ring wrap lost audio")
            }
            try expect(recorder_transport_stats(ring).fault == 0, "Unexpected transport fault")
        }
        await check("Transport preserves stereo and microphone samples") {
            let ring = recorder_transport_create(8, 1, 1, 0)!
            defer { recorder_transport_destroy(ring) }
            let system: [Float] = [0.1, -0.1, 0.2, -0.2]
            let mic: [Float] = [0.3, 0.4]
            let count = system.withUnsafeBufferPointer { s in mic.withUnsafeBufferPointer { m in recorder_transport_feed(ring, s.baseAddress, m.baseAddress, 2, 0, true) } }
            try expect(count == 2, "Feed failed")
            var output = [Float](repeating: 0, count: 6)
            let read = output.withUnsafeMutableBufferPointer { recorder_transport_read(ring, $0.baseAddress, 2) }
            try expect(read == 2 && output == [0.1, -0.1, 0.3, 0.2, -0.2, 0.4], "Source channels changed")
        }
        await check("Buffer overflow freezes capture rather than collapsing the timeline") {
            let ring = recorder_transport_create(2, 0, 0, 0)!
            defer { recorder_transport_destroy(ring) }
            let samples: [Float] = [0, 0, 1, 1]
            _ = samples.withUnsafeBufferPointer { recorder_transport_feed(ring, $0.baseAddress, nil, 2, 0, true) }
            let overflow = samples.withUnsafeBufferPointer { recorder_transport_feed(ring, $0.baseAddress, nil, 1, 2, true) }
            try expect(overflow == 0 && recorder_transport_stats(ring).fault == 1, "Overflow must latch a fault")
            var out = [Float](repeating: 0, count: 4)
            _ = out.withUnsafeMutableBufferPointer { recorder_transport_read(ring, $0.baseAddress, 2) }
            let after = samples.withUnsafeBufferPointer { recorder_transport_feed(ring, $0.baseAddress, nil, 1, 3, true) }
            try expect(after == 0, "Capture resumed silently after loss")
        }
        await check("Timestamp discontinuity and invalid samples are detected") {
            let ring = recorder_transport_create(8, 0, 0, 0)!
            defer { recorder_transport_destroy(ring) }
            let samples: [Float] = [0, 0]
            _ = samples.withUnsafeBufferPointer { recorder_transport_feed(ring, $0.baseAddress, nil, 1, 0, true) }
            _ = samples.withUnsafeBufferPointer { recorder_transport_feed(ring, $0.baseAddress, nil, 1, 100, true) }
            try expect(recorder_transport_stats(ring).fault == 3, "Missing discontinuity fault")
            let invalid = recorder_transport_create(8, 0, 0, 0)!
            defer { recorder_transport_destroy(invalid) }
            let bad: [Float] = [.nan, 0]
            _ = bad.withUnsafeBufferPointer { recorder_transport_feed(invalid, $0.baseAddress, nil, 1, 0, true) }
            try expect(recorder_transport_stats(invalid).fault == 4, "Nonfinite audio accepted")
        }
        await storageRegressionChecks()
        if !CommandLine.arguments.contains("--core-only") {
            await audioChecks()
            await modelChecks()
            await featureRegressionChecks()
            await pauseChecks()
            await renderChecks()
            await deliveryChecks()
        }
        print("\(passed) checks passed; \(failures.count) failed. Temporary evidence: \(root.path)")
        if !failures.isEmpty { exit(1) }
    }

    static func audioChecks() async {
        await check("Stereo export survives opposite-phase channels") {
            let store = try newStore(); let source = try fixture(store, opposite: true)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            try expect(saved.status == .ready && abs((saved.exportedDuration ?? 0) - 1) < 0.1, "Unexpected export result")
            let file = try AVAudioFile(forReading: store.primaryAssetURL(saved))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
            try file.read(into: buffer)
            var stereoDifference: Float = 0
            for i in 0..<Int(buffer.frameLength) { stereoDifference = max(stereoDifference, abs(buffer.floatChannelData![0][i] - buffer.floatChannelData![1][i])) }
            try expect(stereoDifference > 0.2, "Stereo information was collapsed")
            try expect(FileManager.default.fileExists(atPath: store.audioURL(saved.id, segment: 0).path), "Completed source was deleted")
            try expect(saved.primaryAsset?.validationState == .verified, "New export was not tracked as a verified asset")
            try expect(try store.load(saved.id).status == .ready, "Success not persisted")
        }
        await check("Playback pauses, seeks, changes rate and volume, and stops") {
            let store = try newStore(); let source = try fixture(store)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            let playback = PlaybackController(preferences: EphemeralPreferences())
            playback.start(id: saved.id, title: saved.title, url: try store.primaryAssetURL(saved))
            try expect(playback.state == .playing && playback.activeID == saved.id, "Playback did not start")
            playback.pause()
            try expect(playback.state == .paused, "Playback did not pause")
            playback.seek(to: -10)
            try expect(playback.currentTime == 0 && playback.state == .paused, "Paused seek changed playback state or was not clamped")
            playback.seek(to: playback.duration + 10)
            try expect(playback.currentTime == playback.duration, "Forward seek was not clamped")
            playback.setRate(2); playback.setVolume(0.35)
            try expect(playback.rate == 2 && abs(playback.volume - 0.35) < 0.001, "Rate or volume was not applied")
            playback.play()
            try expect(playback.state == .playing, "Playback did not resume")
            playback.stop()
            try expect(playback.state == .stopped && playback.currentTime == 0, "Stop did not reset playback")
            playback.release()
            try expect(playback.activeID == nil, "Release left a stale active player")
            playback.start(id: UUID(), title: "Missing", url: store.root.appendingPathComponent("missing.m4a"))
            try expect(playback.state == .failed && playback.errorMessage != nil, "Missing asset left a phantom player")
        }
        await check("Loud mixed sources export below full scale") {
            let store = try newStore(); let source = try fixture(store, microphone: true, amplitude: 1.8)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            try expect((saved.exportedPeak ?? 2) <= 0.99 && (saved.exportedPeak ?? 0) > 0.5, "Output peak is unsafe or inaudible")
        }
        await check("16 kHz capture resamples to validated stereo AAC") {
            let store = try newStore(); let source = try fixture(store, rate: 16_000)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            let file = try AVAudioFile(forReading: store.primaryAssetURL(saved))
            try expect(file.processingFormat.sampleRate == 48_000 && file.processingFormat.channelCount == 2, "Output format")
            try expect(abs((saved.exportedDuration ?? 0) - 1) < 0.1, "Bluetooth-clock duration changed")
        }
        await check("Multiple recovery segments retain duration") {
            let store = try newStore(); let source = try fixture(store, segments: 3)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            try expect(abs((saved.exportedDuration ?? 0) - 3) < 0.1, "Segmented recording lost duration")
        }
        await check("Complete capture rejects missing microphone and retains originals") {
            let store = try newStore(); let source = try fixture(store, microphone: true)
            try FileManager.default.removeItem(at: store.audioURL(source.id, segment: 0, microphone: true))
            var rejected = false
            do { _ = try await AudioExporter(store: store).export(source) { _ in } } catch { rejected = true }
            try expect(rejected, "Incomplete capture was marked complete")
            try expect(FileManager.default.fileExists(atPath: store.audioURL(source.id, segment: 0).path), "Surviving source deleted")
        }
        await check("Recovery exports the surviving track and retains source files") {
            let store = try newStore(); var source = try fixture(store, microphone: true)
            source.captureCompleted = false; source.status = .interrupted; source.issue = "Microphone interrupted"
            try store.save(source)
            try FileManager.default.removeItem(at: store.audioURL(source.id, segment: 0, microphone: true))
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            try expect(saved.status == .partial, "Partial export mislabeled")
            try expect(FileManager.default.fileExists(atPath: store.audioURL(source.id, segment: 0).path), "Recovery source deleted")
        }
        await check("Truncated source cannot produce a successful recording") {
            let store = try newStore(); let source = try fixture(store)
            let handle = try FileHandle(forWritingTo: store.audioURL(source.id, segment: 0))
            try handle.truncate(atOffset: 100); try handle.close()
            var rejected = false
            do { _ = try await AudioExporter(store: store).export(source) { _ in } } catch { rejected = true }
            try expect(rejected, "Corruption was accepted")
            try expect(FileManager.default.fileExists(atPath: store.audioURL(source.id, segment: 0).path), "Corrupt source deleted")
        }
        await check("Cancelled export preserves its retryable sources") {
            let store = try newStore(); let source = try fixture(store, segments: 3)
            let task = Task { try await AudioExporter(store: store).export(source) { _ in } }
            task.cancel()
            var cancelled = false
            do { _ = try await task.value } catch is CancellationError { cancelled = true }
            try expect(cancelled, "Export ignored cancellation")
            try expect(FileManager.default.fileExists(atPath: store.audioURL(source.id, segment: 0).path), "Cancellation deleted source")
        }
    }

    static func modelChecks() async {
        await check("Playback panel state is driven by the selected saved asset") {
            let store = try newStore(); let source = try fixture(store)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            let trash = RecordingTrashService()
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), exporter: WaitingExporter(),
                                      trashService: trash, preferences: EphemeralPreferences(), observeSleep: false)
            model.refresh()
            try await wait { model.library.sessions.contains(where: { $0.id == saved.id }) }
            try await wait { model.canWorkWithFiles }
            model.togglePlayback(saved)
            try expect(model.playback.activeID == saved.id && model.playback.state == .playing, "Model did not select the saved asset for playback")
            if CommandLine.arguments.contains("--ui-snapshots") { try await snapshot(model, name: "playback-controls", width: 760, height: 1080, light: true) }
            try expect(model.reserveDeletion(saved), "Playback session could not reserve deletion")
            try await model.moveReservedRecordingToTrash(saved)
            try expect(model.playback.activeID == nil && trash.urls == [store.directory(for: saved.id)], "Trash did not release the active player")
            await model.shutdown()
        }
        await check("Delete reservation only removes a row after Trash succeeds") {
            let store = try newStore(); let trash = RecordingTrashService()
            var session = try store.create(); session.status = .recorded; session.captureCompleted = true
            session.segments = [RecordingSegment(index: 0, startFrame: 0, frames: 1, finalized: true)]
            try store.save(session)
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), exporter: WaitingExporter(),
                                      trashService: trash, preferences: EphemeralPreferences(), observeSleep: false)
            model.refresh()
            try await wait { model.library.sessions.contains(where: { $0.id == session.id }) }
            try await wait { model.canWorkWithFiles }
            try expect(model.reserveDeletion(session), "Delete reservation was rejected")
            try await model.moveReservedRecordingToTrash(session)
            try expect(trash.urls == [store.directory(for: session.id)], "Model did not use the exact reserved session")
            try expect(!model.library.sessions.contains(where: { $0.id == session.id }), "Row remained after successful Trash")
            await model.shutdown()
        }
        await check("UI blocks duplicate starts and exposes saving/cancellation states") {
            let store = try newStore()
            let capture = FakeCapture(store: store)
            let model = RecorderModel(store: store, capture: capture, exporter: WaitingExporter(), preferences: EphemeralPreferences(), observeSleep: false)
            try expect(model.phase == .idle, "Initial phase")
            try expect(!model.canWorkWithFiles, "Startup recovery must finish before capture can start")
            try await wait { !model.isInitializing }
            if CommandLine.arguments.contains("--ui-snapshots") { try await snapshot(model, name: "idle", width: 760, height: 820) }
            model.start(); model.start()
            try expect(model.phase == .preparing, "Preparing not visible")
            try await wait { model.phase == .recording }
            let starts = await capture.starts
            try expect(starts == 1, "Duplicate recording started")
            if CommandLine.arguments.contains("--ui-snapshots") { try await snapshot(model, name: "recording", width: 620, height: 640) }
            model.stop()
            try expect(model.phase == .stopping, "Stopping not visible")
            try await wait { model.phase == .exporting }
            if CommandLine.arguments.contains("--ui-snapshots") { try await snapshot(model, name: "exporting", width: 760, height: 820) }
            model.cancelExport()
            try await wait { model.phase == .idle }
            try await wait { model.canWorkWithFiles }
            try expect(model.message.contains("cancelled"), "Cancellation message missing")
            model.maximumMinutes = "invalid"; model.start()
            try expect(model.phase == .failed && model.errorMessage != nil, "Invalid input not visible")
            if CommandLine.arguments.contains("--ui-snapshots") { try await snapshot(model, name: "error-minimum", width: 620, height: 640) }
            model.dismissError()
            try expect(model.phase == .idle, "Error dismiss does not recover")
            var recoverable = try store.create()
            recoverable.status = .interrupted
            recoverable.segments = [RecordingSegment(index: 0, startFrame: 0, frames: 48_000)]
            try store.save(recoverable)
            try await wait { model.canWorkWithFiles }
            model.recover(recoverable); model.recover(recoverable)
            try expect(model.phase == .exporting, "Recovery did not lock controls synchronously")
            model.cancelExport()
            try await wait { model.phase == .idle }
            if CommandLine.arguments.contains("--ui-snapshots") {
                model.includeMicrophone = true; model.microphoneID = UInt32.max
                recoverable.issue = String(repeating: "The microphone was disconnected. The available audio has been kept. ", count: 3)
                try store.save(recoverable); model.refresh()
                try await snapshot(model, name: "light-microphone-minimum", width: 620, height: 640, light: true)
                try await snapshot(model, name: "light-recovery", width: 760, height: 1200, light: true)
            }
            await model.shutdown()
        }
    }
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Timed out waiting for UI state")
    }
    static func snapshot(_ model: RecorderModel, name: String, width: CGFloat, height: CGFloat, light: Bool = false) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(description: "No UI bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = root.appendingPathComponent("\(name).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
        print("SNAPSHOT \(url.path)")
    }
}

actor FakeCapture: Capturing {
    let store: SessionStore
    var session: RecordingSession?
    var starts = 0
    init(store: SessionStore) { self.store = store }
    func start(session: RecordingSession, options: CaptureOptions, event: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        starts += 1; self.session = session
        try await Task.sleep(for: .milliseconds(50))
        var recording = session; recording.status = .recording
        try store.save(recording)
        event(.meter(CaptureMeter(elapsed: 125, system: 0.2, microphone: 0, sampleRate: 48_000)))
    }
    func stop(reason: String?) async throws -> RecordingSession {
        var result = session!
        result.status = reason == nil ? .recorded : .interrupted
        result.captureCompleted = reason == nil; result.issue = reason
        try store.save(result)
        return result
    }
    func pause() async throws -> CaptureSnapshot {
        var current = session!; current.status = .paused; session = current
        return CaptureSnapshot(session: current, recordedFrames: 0)
    }
    func resume() async throws -> CaptureSnapshot {
        var current = session!; current.status = .recording; session = current
        return CaptureSnapshot(session: current, recordedFrames: 0)
    }
}
final class EphemeralPreferences: UserDefaults, @unchecked Sendable {
    override func bool(forKey defaultName: String) -> Bool { false }
    override func string(forKey defaultName: String) -> String? { nil }
    override func set(_ value: Any?, forKey defaultName: String) {}
}
struct WaitingExporter: AudioExporting {
    func export(_ session: RecordingSession, progress: @escaping @Sendable (Double) -> Void) async throws -> RecordingSession {
        progress(0.5)
        try await Task.sleep(for: .seconds(30))
        return session
    }
}

final class RecordingTrashService: TrashService, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [URL] = []
    private var fail = false

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return calls }
    var shouldFail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); fail = newValue; lock.unlock() }
    }
    func trash(_ directory: URL) throws {
        lock.lock(); calls.append(directory); let shouldFail = fail; lock.unlock()
        if shouldFail { throw RecorderFailure("Trash is unavailable") }
    }
}
