import AppKit
import AVFoundation
import Foundation
import RecorderAudio
import RecorderCore
@testable import RecorderUI

extension RecorderChecks {
    static func storageRegressionChecks() async {
        await check("Oversized legacy duration is isolated without rewriting the manifest") {
            let store = try newStore(); let session = try store.create()
            let url = store.directory(for: session.id).appendingPathComponent("session.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            object["schemaVersion"] = 1; object["status"] = "ready"
            for duration in [-1.0, 1e30, Double(Int64.max) / 48_000] {
                object["exportedDuration"] = duration
                let bytes = try JSONSerialization.data(withJSONObject: object)
                try bytes.write(to: url)
                try expect(try store.list().unreadable == 1, "Invalid duration was accepted")
                try expect(try Data(contentsOf: url) == bytes, "Bad metadata was rewritten")
            }
            object["schemaVersion"] = 99
            let future = try JSONSerialization.data(withJSONObject: object)
            try future.write(to: url)
            try expect(try store.list(recoverInterrupted: true).unreadable == 1, "Future schema was accepted")
            try expect(try Data(contentsOf: url) == future, "Future schema was overwritten")
        }
        await check("Verified assets require measurements and intermediate symlinks are rejected") {
            let store = try newStore(); let session = try store.create()
            let outside = store.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try Data([1]).write(to: outside.appendingPathComponent("audio.m4a"))
            var asset = RecordingAsset(relativePath: "exports/audio.m4a", container: .m4a, codec: .aac,
                                       sampleRate: 48_000, channelCount: 2, validationState: .verified)
            try expectFailure { try asset.validate() }
            asset.decodedFrameCount = 48_000; asset.duration = 1; asset.peak = 0.2; asset.byteSize = 1
            try asset.validate()
            try FileManager.default.createSymbolicLink(at: store.directory(for: session.id).appendingPathComponent("exports"), withDestinationURL: outside)
            try expectFailure { _ = try store.assetURL(session, asset: asset) }
            asset.codec = .flac
            try expectFailure { try asset.validate() }
        }
        await check("Metadata patches preserve newer fields and existing long names") {
            let store = try newStore(); var old = try store.create()
            old.title = String(repeating: "L", count: 200); try store.save(old)
            let favorite = try store.toggleFavorite(id: old.id)
            try expect(favorite.isFavorite && favorite.title == old.title, "Favorite could not preserve a legacy name")
            _ = try store.updateLibraryMetadata(id: old.id, title: "New title", tags: ["New tag"])
            let latest = try store.toggleFavorite(id: old.id)
            try expect(latest.title == "New title" && latest.tags == ["New tag"] && !latest.isFavorite, "Favorite overwrote newer metadata")
            try expectFailure { _ = try LibraryRules.normalizedTitle("Name\n") }
            try expectFailure { _ = try LibraryRules.normalizedTags("Tag\t") }
            try expect(try LibraryRules.normalizedTags(Array(repeating: "same", count: 11).joined(separator: ",")) == ["same"], "Duplicate tags incorrectly exceeded the limit")
        }
        await check("Metadata write failure preserves the previous manifest") {
            let fault = ManifestFault()
            let store = try SessionStore(root: root.appendingPathComponent(UUID().uuidString), beforeManifestWrite: { _ in try fault.check() })
            let session = try store.create()
            let manifest = store.directory(for: session.id).appendingPathComponent("session.json")
            let before = try Data(contentsOf: manifest)
            fault.enabled = true
            try expectFailure { _ = try store.updateLibraryMetadata(id: session.id, title: "Unsaved") }
            try expect(try Data(contentsOf: manifest) == before, "Failed edit replaced the manifest")
        }
        await check("Stale library scans cannot restore edited or deleted rows") {
            let store = try newStore(); let original = try store.create()
            let gate = SnapshotGate()
            let library = RecordingLibrary(store: store, loader: { _ in await gate.load() })
            let initial = LibrarySnapshot(sessions: [original], unreadable: 0, managedBytes: [:])
            library.refresh(); try await wait { gate.isWaiting }; gate.finish(initial)
            await library.refreshTask?.value
            library.selectedID = original.id
            library.refresh(); try await wait { gate.isWaiting }
            var edited = original; edited.title = "Updated"
            library.replace(edited); gate.finish(initial); await library.refreshTask?.value
            try expect(library.sessions.first?.title == "Updated", "Old scan restored stale metadata")
            library.refresh(); try await wait { gate.isWaiting }
            library.remove(id: original.id); gate.finish(initial); await library.refreshTask?.value
            try expect(library.sessions.isEmpty && library.selectedID == nil, "Old scan resurrected a deleted row")
        }
        await check("Library filters handle 1000 recordings with deterministic ordering") {
            let sessions = (0..<1000).map { index in
                var session = RecordingSession(createdAt: Date(timeIntervalSince1970: Double(index)), title: "Meeting \(index)")
                session.tags = [index.isMultiple(of: 2) ? "Team" : "Personal"]
                return session
            }
            let query = LibraryQuery(searchText: "meeting", selectedTags: ["team"], sort: .newestFirst)
            let result = query.applying(to: sessions)
            try expect(result.count == 500 && result.first?.title == "Meeting 998", "Large library filtering or ordering failed")
        }
    }

    static func featureRegressionChecks() async {
        await check("Playback adapter rejects stale callbacks and reports decode/play failures") {
            let first = ControlledPlayer(), second = ControlledPlayer()
            let firstID = UUID(), secondID = UUID()
            let playback = PlaybackController(preferences: EphemeralPreferences(), makePlayer: { url in
                url.lastPathComponent == "first" ? first : second
            })
            defer { playback.release() }
            playback.start(id: firstID, title: "First", url: URL(fileURLWithPath: "/first"))
            let lateCompletion = first.completion!
            playback.start(id: secondID, title: "Second", url: URL(fileURLWithPath: "/second"))
            lateCompletion(false, "Stale failure")
            for _ in 0..<10 { await Task.yield() }
            try expect(playback.activeID == secondID && playback.state == .playing, "Old callback changed the new player")
            playback.setRate(2)
            try expect(second.enableRate && second.rate == 2 && playback.duration == 60, "Playback rate changed source duration")
            playback.seek(to: 60)
            try expect(playback.state == .finished && !second.isPlaying, "Seek to end restarted playback")
            playback.skip(by: -10)
            try expect(playback.currentTime == 50 && playback.state == .paused, "Back from completion used the reset native time")
            playback.play(); second.completion?(false, "Injected decode error")
            try await wait { playback.state == .failed }
            try expect(playback.errorMessage == "Injected decode error" && !second.isPlaying, "Decode failure left playback running")
            second.canPlay = false
            playback.start(id: secondID, title: "Unplayable", url: URL(fileURLWithPath: "/second"))
            try expect(playback.state == .failed, "Unsuccessful play reported playing")
        }
        await check("Failed export commit retains tracked output and recovers without duplicate assets") {
            let folder = root.appendingPathComponent(UUID().uuidString)
            let fault = ManifestFault()
            let store = try SessionStore(root: folder, beforeManifestWrite: { id in
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + "/pending-export.json").path) { try fault.check() }
            })
            let source = try fixture(store)
            fault.enabled = true
            do {
                _ = try await AudioExporter(store: store).export(source) { _ in }
                throw CheckFailure(description: "Commit fault was ignored")
            } catch is CheckFailure { throw CheckFailure(description: "Commit fault was ignored") }
            catch { /* Expected injected manifest failure, after successful audio promotion. */ }
            guard let pending = try store.pendingExport(source.id) else { throw CheckFailure(description: "Pending journal was lost") }
            try expect(FileManager.default.fileExists(atPath: try store.pendingAudioURL(pending).path), "Promoted audio was removed")
            try expect(try store.librarySnapshot().pendingExports.contains(source.id), "Unfinished save was hidden")
            fault.enabled = false
            _ = try store.updateLibraryMetadata(id: source.id, title: "Edited after failure", tags: ["Kept"])
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            try expect(saved.assets.count == 1 && saved.primaryAssetID == pending.asset.id && saved.title == "Edited after failure" && saved.tags == ["Kept"], "Recovery duplicated output or overwrote edits")
            try expect(try store.pendingExport(saved.id) == nil, "Committed journal was not cleared")
            try expect(FileManager.default.fileExists(atPath: store.audioURL(source.id, segment: 0).path), "Recovery discarded source audio")
            let usage = store.storageUsage(for: saved)
            try expect(usage.sources > 300_000 && usage.total > usage.sources, "Retained-source bytes were omitted from storage totals")
        }
        await check("Natural playback completion, replay, paused seek and scrubbing stay synchronized") {
            let store = try newStore(); let url = store.root.appendingPathComponent("silence.wav")
            try makeAudio(url, sampleRate: 48_000, channels: 2, seconds: 0.5, amplitude: 0)
            let playback = PlaybackController(preferences: EphemeralPreferences())
            defer { playback.release() }
            playback.start(id: UUID(), title: "Short silence", url: url)
            try await wait { playback.state == .finished }
            try expect(abs(playback.currentTime - 0.5) < 0.01, "Natural finish reset the display to zero")
            playback.play()
            try expect(playback.state == .playing && playback.currentTime < 0.1, "Replay did not restart from zero")
            playback.beginScrubbing(); playback.updateScrubPosition(0.3)
            try await Task.sleep(for: .milliseconds(150))
            try expect(playback.displayedTime == 0.3, "Timer changed the scrub draft")
            playback.endScrubbing(); playback.pause()
            let paused = playback.currentTime
            try await Task.sleep(for: .milliseconds(150))
            try expect(playback.state == .paused && playback.currentTime == paused, "Pause did not freeze playback")
            playback.seek(to: .nan); try expect(playback.currentTime == paused, "NaN seek changed position")
            playback.seek(to: 0.1); playback.play()
            try await wait { playback.state == .finished }
            playback.seek(to: 0.25); playback.play()
            try expect(playback.currentTime >= 0.24, "Seeking after completion was discarded on Play")
        }
        await check("Finder failure cannot change a live capture phase or disable Stop") {
            let store = try newStore(); let capture = FakeCapture(store: store)
            let model = RecorderModel(store: store, capture: capture, exporter: WaitingExporter(), preferences: EphemeralPreferences(), observeSleep: false)
            try await wait { !model.isInitializing }
            model.start(); try await wait { model.phase == .recording }
            model.refresh()
            try expect(!model.library.isRefreshing, "A library scan competed with the capture writer")
            var missing = RecordingSession(); missing.status = .ready
            model.reveal(missing)
            try expect(model.phase == .recording && model.errorMessage != nil, "Finder error corrupted capture state")
            model.stop(reason: "Test stop")
            try await wait { model.phase == .idle }
            await model.shutdown()
        }
        await check("Metadata mutation blocks competing commands and Quit waits for disk completion") {
            let gate = ManifestGate()
            let store = try SessionStore(root: root.appendingPathComponent(UUID().uuidString), beforeManifestWrite: { _ in gate.waitIfArmed() })
            var session = try store.create(); session.status = .interrupted; try store.save(session)
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), exporter: WaitingExporter(), preferences: EphemeralPreferences(), observeSleep: false)
            try await wait { !model.isInitializing }
            gate.arm()
            model.toggleFavorite(session)
            defer { gate.release() }
            try await wait { gate.hasEntered }
            try expect(!model.canWorkWithFiles && !model.canMutateLibrary, "Metadata mutation did not reserve commands")
            model.start(); try expect(model.phase == .idle, "Capture started during a metadata write")
            var finishedQuit = false
            let quit = Task { await model.shutdown(); finishedQuit = true }
            try await Task.sleep(for: .milliseconds(30))
            try expect(!finishedQuit, "Quit skipped the pending metadata write")
            gate.release(); await quit.value
            try expect(try store.load(session.id).isFavorite, "Metadata was not durable before quit")
        }
        await check("Trash cancellation, failure, repeat requests and restoration preserve independent files") {
            let store = try newStore(); var session = try fixture(store, amplitude: 0)
            session.status = .interrupted; try store.save(session)
            let other = try store.create()
            let copy = store.root.appendingPathComponent("external-copy.m4a")
            try Data([1, 2, 3]).write(to: copy)
            let trash = FixtureTrash(destination: root.appendingPathComponent("test-trash-\(UUID().uuidString)"))
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), exporter: WaitingExporter(), trashService: trash, preferences: EphemeralPreferences(), observeSleep: false)
            try await wait { !model.isInitializing }
            try expect(model.reserveDeletion(session), "Could not reserve deletion")
            try expect(!model.reserveDeletion(session), "Duplicate reservation succeeded")
            model.cancelDeletion(session)
            try expect(trash.calls == 0, "Cancel invoked Trash")
            try await wait { !model.library.isRefreshing }
            trash.shouldFail = true
            try expect(model.reserveDeletion(session), "Retry could not reserve")
            do { try await model.moveReservedRecordingToTrash(session); throw CheckFailure(description: "Expected failure") }
            catch is CheckFailure { throw CheckFailure(description: "Expected Trash failure") } catch {}
            try expect(model.library.sessions.contains { $0.id == session.id }, "Failure removed the row")
            trash.shouldFail = false
            try await model.moveReservedRecordingToTrash(session)
            try await wait { !model.library.isRefreshing }
            try expect(!model.library.sessions.contains { $0.id == session.id }, "Deleted row reappeared after refresh")
            try expect(try store.load(other.id).id == other.id && Data(contentsOf: copy) == Data([1, 2, 3]), "Trash touched independent files")
            try FileManager.default.moveItem(at: trash.destination.appendingPathComponent(session.id.uuidString), to: store.directory(for: session.id))
            model.refresh(); try await wait { model.library.sessions.contains { $0.id == session.id } }
            try expect(try store.load(session.id).segments == session.segments, "Restoration lost sources/metadata")
            await model.shutdown()
        }
        await check("Playback survives filters, follows renames, and releases missing files") {
            let store = try newStore(); let source = try fixture(store, amplitude: 0)
            let saved = try await AudioExporter(store: store).export(source) { _ in }
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), preferences: EphemeralPreferences(), observeSleep: false)
            try await wait { !model.isInitializing }
            model.togglePlayback(saved); model.playback.pause()
            model.library.searchText = "no matches"
            try expect(model.playingID == saved.id, "Filtering stopped playback")
            let window = PlaybackWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.recorder = model
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            window.keyDown(with: space)
            try expect(model.playback.state == .playing, "Space did not resume playback")
            let editor = NSTextView(frame: .zero); window.contentView = editor; window.makeFirstResponder(editor)
            window.keyDown(with: space)
            try expect(model.playback.state == .playing, "Space in a text editor toggled playback")
            model.playback.pause()
            model.library.clearFilters()
            try await model.saveLibraryDetails(saved, title: "A renamed recording with a long descriptive title for a narrow window", tagsText: (0..<10).map { "Tag\($0)-long-description" }.joined(separator: ","))
            try await wait { !model.library.isRefreshing }
            try expect(model.playback.title.hasPrefix("A renamed"), "Player title did not follow rename")
            if CommandLine.arguments.contains("--ui-snapshots") {
                try await snapshot(model, name: "library-playback-minimum-light", width: 620, height: 1400, light: true)
                try await snapshot(model, name: "library-playback-minimum-dark", width: 620, height: 1400)
            }
            let url = try store.primaryAssetURL(saved)
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("moved"))
            model.refresh(); try await wait { !model.library.isRefreshing }
            try expect(model.playingID == nil && model.library.missingAssets.contains(saved.id), "Missing file left a stale player")
            await model.shutdown()
        }
    }
}

private final class ManifestFault: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func check() throws { if enabled { throw RecorderFailure("Injected manifest write failure") } }
}

private final class SnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LibrarySnapshot, Never>?
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    func load() async -> LibrarySnapshot {
        await withCheckedContinuation { next in lock.withLock { continuation = next } }
    }
    func finish(_ snapshot: LibrarySnapshot) {
        let next = lock.withLock { let next = continuation; continuation = nil; return next }
        next?.resume(returning: snapshot)
    }
}

private final class ManifestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    var hasEntered: Bool { lock.withLock { entered } }
    func arm() { lock.withLock { armed = true } }
    func waitIfArmed() {
        let wait = lock.withLock { if !armed { return false }; armed = false; entered = true; return true }
        if wait { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}

/// Uses only generated fixtures and a private temporary folder, never the user's Trash.
final class FixtureTrash: TrashService, @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private var count = 0
    private var fail = false
    init(destination: URL) { self.destination = destination }
    var calls: Int { lock.withLock { count } }
    var shouldFail: Bool {
        get { lock.withLock { fail } }
        set { lock.withLock { fail = newValue } }
    }
    func trash(_ directory: URL) throws {
        let shouldFail = lock.withLock { count += 1; return fail }
        if shouldFail { throw RecorderFailure("Injected Trash failure") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: destination.appendingPathComponent(directory.lastPathComponent))
    }
}

@MainActor
private final class ControlledPlayer: PlaybackPlayer {
    var duration: TimeInterval = 60
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var enableRate = false
    var rate: Float = 1
    var volume: Float = 1
    var canPlay = true
    var completion: (@Sendable (Bool, String?) -> Void)?
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { isPlaying = canPlay; return canPlay }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
    func setCompletion(_ completion: (@Sendable (Bool, String?) -> Void)?) { self.completion = completion }
}
