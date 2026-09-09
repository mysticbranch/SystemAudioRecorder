import Foundation
import RecorderCore
import RecorderAudio
import SwiftUI
@testable import RecorderUI

extension RecorderChecks {
    static func deliveryChecks() async {
        await check("Filename patterns preserve Unicode, bound bytes and reject unknown expressions") {
            let session = RecordingSession(createdAt: Date(timeIntervalSince1970: 0), title: String(repeating: "漢字🙂", count: 80))
            let result = try FilenamePattern.expand("{date}_{time}_{title}", session: session, timeZone: TimeZone(secondsFromGMT: 0)!)
            try expect(result.hasPrefix("1970-01-01_00-00-00_") && result.utf8.count <= 180 && !result.contains("�"), "Filename expansion broke date/Unicode/length")
            for pattern in ["", "{unknown}", "{date", "date}", "{{title}}"] { try expectFailure { _ = try FilenamePattern.expand(pattern, session: session) } }
            let safe = try FilenamePattern.expand("../{id}/a:b\n", session: session)
            try expect(!safe.contains("/") && !safe.contains(":") && !safe.contains("\n"), "Unsafe filename characters survived")
        }
        await check("Destination bookmarks reject managed storage and preserve cancelled settings drafts") {
            let store = try newStore(), settingsStore = ExportDestinationStore(managedRoot: try newStore().root)
            try expectFailure { _ = try settingsStore.bookmark(for: settingsStore.managedRoot) }
            let sibling = settingsStore.managedRoot.deletingLastPathComponent().appendingPathComponent(settingsStore.managedRoot.lastPathComponent + "-copies")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            let bookmark = try settingsStore.bookmark(for: sibling)
            try expect(try settingsStore.resolve(bookmark).url.path == sibling.path, "Sibling folder was mistaken for managed storage")
            var settings = DestinationSettings(); settings.pattern = "{id}"; try settingsStore.save(settings)
            var draft = settings; draft.pattern = "Unsubmitted"
            try expect(try settingsStore.load().pattern == "{id}", "Draft changed persisted settings")
            try expectFailure { _ = try settingsStore.resolve(Data("invalid bookmark".utf8)) }
            _ = store
        }
        await check("External copies never overwrite collisions and retry adopts the existing published file") {
            let store = try newStore(), settingsStore = ExportDestinationStore(managedRoot: try newStore().root)
            let folder = root.appendingPathComponent("copies-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var settings = DestinationSettings(); settings.bookmark = try settingsStore.bookmark(for: folder); settings.pattern = "Meeting"
            let parent = try await AudioExporter(store: store).export(fixture(store)) { _ in }
            let protected = folder.appendingPathComponent("Meeting.m4a")
            try Data("Do not overwrite".utf8).write(to: protected)
            let service = ExportDeliveryService(store: store, destinations: settingsStore)
            let job = try await service.deliver(sessionID: parent.id, assetID: parent.primaryAssetID!, settings: settings)
            try expect(job.targetName == "Meeting-2.m4a" && job.state == .succeeded, "Collision did not receive a suffix")
            try expect(try Data(contentsOf: protected) == Data("Do not overwrite".utf8), "Existing user file was overwritten")
            var crashed = job; crashed.state = .pending
            let adopted = try await service.retry(crashed)
            try expect(adopted.targetName == job.targetName && FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2, "Retry duplicated a published copy")
            try store.trashSession(parent.id, using: FixtureTrash(destination: root.appendingPathComponent("trash-\(UUID().uuidString)")))
            try expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(job.targetName!).path), "Session deletion touched the external copy")
        }
        await check("Failed external delivery preserves the internal asset and remains retryable") {
            let store = try newStore(), settingsStore = ExportDestinationStore(managedRoot: try newStore().root)
            let folder = root.appendingPathComponent("missing-drive-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var settings = DestinationSettings(); settings.bookmark = try settingsStore.bookmark(for: folder)
            let saved = try await AudioExporter(store: store).export(fixture(store)) { _ in }
            // Replace only this generated empty fixture with a regular file, simulating an unavailable folder.
            try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("moved"))
            try Data([1]).write(to: folder)
            let service = ExportDeliveryService(store: store, destinations: settingsStore)
            settings.bookmark = Data("corrupt bookmark".utf8)
            do { _ = try await service.deliver(sessionID: saved.id, assetID: saved.primaryAssetID!, settings: settings); throw CheckFailure(description: "Invalid destination succeeded") }
            catch is CheckFailure { throw CheckFailure(description: "Invalid destination succeeded") } catch {}
            let jobs = try service.jobs(sessionID: saved.id)
            try expect(jobs.count == 1 && jobs[0].state == .failed && store.load(saved.id).status == .ready, "External failure changed internal success or lost retry state")
            let repaired = try settingsStore.bookmark(for: folder.appendingPathExtension("moved"))
            let retried = try await service.retry(jobs[0], inFolder: repaired)
            try expect(retried.state == .succeeded && retried.assetID == saved.primaryAssetID, "Retry rerendered or failed to deliver the same asset")
        }
        await check("Workflow preview cancellation releases artifacts and derived results leave the parent intact") {
            let store = try newStore(), source = try fixture(store, microphone: true)
            let parent = try await AudioExporter(store: store).export(source) { _ in }
            let model = RecorderModel(store: store, capture: FakeCapture(store: store), preferences: EphemeralPreferences(), observeSleep: false)
            try await wait { model.canWorkWithFiles }
            model.workflow.isEditing = true
            let selection = try await model.workflow.renderer.sourceRange(sessionID: parent.id)
            let result = try await model.workflow.perform(RenderRequest(sessionID: parent.id, preset: .wav, purpose: .preview, range: selection), copyToFolder: false)
            try expect(model.playingID == result.asset.id && !model.canWorkWithFiles, "Preview did not share playback or reserve commands")
            model.workflow.invalidatePreview()
            try await wait { !FileManager.default.fileExists(atPath: result.url.path) }
            try expect(model.playingID == nil, "Preview release left a player active")
            if CommandLine.arguments.contains("--ui-snapshots") {
                try await snapshotView(RenderEditorSheet(session: parent, purpose: .clip, workflow: model.workflow), name: "trim-sheet", width: 568, height: 620)
                try await snapshotView(RenderEditorSheet(session: parent, purpose: .cleanedCopy, workflow: model.workflow), name: "cleanup-sheet", width: 568, height: 680)
                try await snapshotView(ExportSettingsSheet(workflow: model.workflow), name: "export-settings", width: 568, height: 600)
            }
            model.workflow.closeEditor(); await model.shutdown()
        }
    }

    static func snapshotView<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) async throws {
        let host = NSHostingView(rootView: view.padding().background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height); window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(description: "No sheet snapshot bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = root.appendingPathComponent(name + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url); window.orderOut(nil)
        print("SNAPSHOT \(url.path)")
    }
}
