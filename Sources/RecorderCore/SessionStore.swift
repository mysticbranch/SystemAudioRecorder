import Foundation
import Darwin

/// Serializes filesystem operations. Callers never invoke this from the audio callback.
public final class SessionStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let beforeManifestWrite: (@Sendable (UUID) throws -> Void)?

    public init(root: URL? = nil, beforeManifestWrite: (@Sendable (UUID) throws -> Void)? = nil) throws {
        self.beforeManifestWrite = beforeManifestWrite
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.mysticbranch.SystemAudioRecorder/Sessions", isDirectory: true)
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try rejectSymbolicLink(self.root)
    }
    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func audioURL(_ id: UUID, segment: Int, microphone: Bool = false) -> URL {
        directory(for: id).appendingPathComponent(String(format: "%05d-%@.caf", segment, microphone ? "microphone" : "system"))
    }
    /// Legacy convenience for callers that only have an id. New code should use `primaryAssetURL(_:)`.
    public func exportURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("Recording.m4a") }

    public func create() throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        let session = RecordingSession()
        try FileManager.default.createDirectory(at: directory(for: session.id), withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        try save(session)
        return session
    }
    public func createDerived(parent: RecordingSession, kind: RecordingKind, title: String, range: AudioFrameRange, request: RenderRequest? = nil) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        guard kind == .clip || kind == .cleanedCopy else { throw RecorderFailure("Invalid derived recording type.") }
        var session = RecordingSession(title: try LibraryRules.normalizedTitle(title))
        session.kind = kind; session.sourceRetention = .notApplicable; session.status = .pendingRender
        session.issue = parent.issue ?? (parent.status == .partial || !parent.captureCompleted && parent.kind == .capture ? "Created from a partial recording." : nil)
        session.derivation = AudioDerivation(parentSessionID: parent.id, parentAssetID: parent.primaryAssetID, range: range)
        try FileManager.default.createDirectory(at: directory(for: session.id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let request {
            let job = PendingRenderJob(ownerID: session.id, request: request)
            try job.validate()
            let url = pendingRenderURL(session.id)
            try encoder.encode(job).write(to: url, options: .atomic)
            try synchronizeFileAndDirectory(url, directory: directory(for: session.id))
        }
        try save(session)
        return session
    }
    public func createPreviewDirectory() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try rejectSymbolicLink(root)
        let previews = root.appendingPathComponent(".previews", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymbolicLink(previews)
        let folder = previews.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }
    public func discardPreviewDirectory(_ folder: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let previews = root.appendingPathComponent(".previews").standardizedFileURL
        guard folder.deletingLastPathComponent().standardizedFileURL == previews,
              UUID(uuidString: folder.lastPathComponent) != nil else { throw RecorderFailure("The preview path is outside temporary storage.") }
        try rejectSymbolicLink(root); try rejectSymbolicLink(previews)
        if FileManager.default.fileExists(atPath: folder.path) {
            try rejectSymbolicLink(folder); try FileManager.default.removeItem(at: folder)
        }
    }
    public func save(_ session: RecordingSession) throws {
        lock.lock(); defer { lock.unlock() }
        try session.validate()
        let directory = directory(for: session.id)
        try rejectSymbolicLink(directory)
        let url = directory.appendingPathComponent("session.json")
        try beforeManifestWrite?(session.id)
        try preserveV1ManifestBeforeMigration(at: url, in: directory)
        try encoder.encode(session).write(to: url, options: .atomic)
        try synchronizeFileAndDirectory(url, directory: directory)
    }
    public func updateLibraryMetadata(id: UUID, title: String? = nil, tags: [String]? = nil, isFavorite: Bool? = nil) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        var session = try load(id)
        if let title, title != session.title { session.title = try LibraryRules.normalizedTitle(title) }
        if let tags { session.tags = try normalizeTags(tags) }
        if let isFavorite { session.isFavorite = isFavorite }
        try save(session)
        return session
    }
    /// Only the renderer calls this for a newly allocated failed/cancelled derived job.
    /// A promoted or committed asset is never removed by cancellation cleanup.
    public func discardUncommittedDerived(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let session = try load(id)
        guard session.kind != .capture, session.status == .pendingRender, session.assets.isEmpty,
              try pendingExport(id) == nil, try pendingRender(id) == nil else { return }
        try FileManager.default.removeItem(at: directory(for: id))
    }
    public func toggleFavorite(id: UUID) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        var session = try load(id)
        session.isFavorite.toggle()
        try save(session)
        return session
    }
    public func updateExportStatus(id: UUID, status: SessionStatus) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        var session = try load(id)
        session.status = status
        try save(session)
        return session
    }
    public func primaryAssetURL(_ session: RecordingSession) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let asset = session.primaryAsset else { throw RecorderFailure("This recording has no saved audio.") }
        return try assetURL(session, asset: asset)
    }
    public func assetURL(_ session: RecordingSession, asset: RecordingAsset) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try asset.validate()
        let directory = directory(for: session.id).standardizedFileURL
        guard RecordingPath.isSafeRelativePath(asset.relativePath) else { throw RecorderFailure("The saved-audio path is unsafe.") }
        try rejectSymbolicLink(root)
        try rejectSymbolicLink(directory)
        let url = directory.appendingPathComponent(asset.relativePath).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else { throw RecorderFailure("The saved-audio path escapes its recording folder.") }
        var componentURL = directory
        for component in asset.relativePath.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            try rejectSymbolicLink(componentURL)
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecorderFailure("The saved audio is not a regular file.")
        }
        return url
    }
    public func managedBytes(for session: RecordingSession) -> Int64 {
        storageUsage(for: session).total
    }
    public func storageUsage(for session: RecordingSession) -> (total: Int64, sources: Int64) {
        lock.lock(); defer { lock.unlock() }
        let directory = directory(for: session.id)
        guard (try? rejectSymbolicLink(directory)) != nil,
              let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return (0, 0) }
        var total: Int64 = 0
        var sources: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
            if url.pathExtension == "caf", url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
                sources += Int64(values.fileSize ?? 0)
            }
        }
        return (total, sources)
    }
    private func synchronizeFileAndDirectory(_ url: URL, directory: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    public func load(_ id: UUID) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        let directory = directory(for: id)
        try rejectSymbolicLink(directory)
        let url = directory.appendingPathComponent("session.json")
        try rejectSymbolicLink(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 16_000_000 else {
            throw RecorderFailure("The recording metadata is too large.")
        }
        let session = try decoder.decode(RecordingSession.self, from: Data(contentsOf: url))
        guard session.id == id else { throw RecorderFailure("The recording identity does not match its folder.") }
        try session.validate()
        return session
    }
    public func list(recoverInterrupted: Bool = false) throws -> (sessions: [RecordingSession], unreadable: Int) {
        lock.lock(); defer { lock.unlock() }
        var sessions: [RecordingSession] = []
        var unreadable = 0
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            do {
                var session = try load(id)
                if recoverInterrupted {
                    switch session.status {
                    case .preparing, .recording, .pausing, .paused, .resuming:
                        session.status = .interrupted
                        session.captureCompleted = false
                        session.issue = "The app closed before recording finished. Recover the available audio."
                        try save(session)
                    case .exporting:
                        session.status = session.captureCompleted ? .recorded : .interrupted
                        try save(session)
                    default: break
                    }
                }
                sessions.append(session)
            } catch { unreadable += 1 }
        }
        return (sessions.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }
    public func librarySnapshot(recoverInterrupted: Bool = false) throws -> LibrarySnapshot {
        lock.lock(); defer { lock.unlock() }
        let result = try list(recoverInterrupted: recoverInterrupted)
        var bytes: [UUID: Int64] = [:]
        var sources: [UUID: Int64] = [:]
        var missing = Set<UUID>()
        var pending = Set<UUID>()
        let delivery = ExportDeliveryService(store: self, destinations: ExportDestinationStore(managedRoot: root))
        var deliveries: [DeliveryJob] = [], unreadableDeliveries = false
        for session in result.sessions {
            let usage = storageUsage(for: session)
            bytes[session.id] = usage.total; sources[session.id] = usage.sources
            if session.primaryAsset != nil, (try? primaryAssetURL(session)) == nil { missing.insert(session.id) }
            if FileManager.default.fileExists(atPath: pendingExportURL(session.id).path) ||
                FileManager.default.fileExists(atPath: pendingRenderURL(session.id).path) { pending.insert(session.id) }
            do { deliveries += try delivery.jobs(sessionID: session.id).filter { $0.state != .succeeded } }
            catch { unreadableDeliveries = true }
        }
        return LibrarySnapshot(sessions: result.sessions, unreadable: result.unreadable, managedBytes: bytes,
                               sourceBytes: sources, missingAssets: missing, pendingExports: pending,
                               pendingDeliveries: deliveries, hasUnreadableDeliveries: unreadableDeliveries)
    }
    /// Validates and moves exactly one direct session child to Trash. It never falls back to permanent deletion.
    public func trashSession(_ id: UUID, using service: any TrashService) throws {
        lock.lock(); defer { lock.unlock() }
        let managedRoot = root.standardizedFileURL
        let directory = directory(for: id).standardizedFileURL
        guard directory.deletingLastPathComponent() == managedRoot,
              directory.lastPathComponent == id.uuidString,
              FileManager.default.fileExists(atPath: directory.path) else {
            throw RecorderFailure("This recording is no longer available in the app's storage.")
        }
        try rejectSymbolicLink(managedRoot)
        try rejectSymbolicLink(directory)
        let session = try load(id)
        guard session.id == id else { throw RecorderFailure("The recording identity does not match its folder.") }
        try service.trash(directory)
    }
    public func completeExport(_ session: RecordingSession, temporaryURL: URL, duration: Double, peak: Float) throws -> RecordingSession {
        try commitRendered(sessionID: session.id, temporaryURL: temporaryURL, preset: .balanced,
                           frames: RecordingLimits.frameCount(seconds: duration, sampleRate: 48_000), peak: peak, purpose: .primary)
    }
    public func commitRendered(sessionID: UUID, temporaryURL: URL, preset: ExportPreset, frames: Int64, peak: Float,
                               purpose: RenderPurpose, provenance: RenderProvenance? = nil) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        let directory = directory(for: sessionID).standardizedFileURL
        guard temporaryURL.deletingLastPathComponent().standardizedFileURL == directory,
              temporaryURL.lastPathComponent.hasPrefix("export-") else {
            throw RecorderFailure("The export is outside its recording folder.")
        }
        try rejectSymbolicLink(temporaryURL)
        guard frames > 0, peak.isFinite, peak >= 0, peak <= 0.99, purpose != .preview else {
            throw RecorderFailure("The export result is invalid.")
        }
        // Reload under the same lock so an edit made while exporting is not overwritten.
        _ = try load(sessionID)
        let exports = directory.appendingPathComponent("exports", isDirectory: true)
        if FileManager.default.fileExists(atPath: exports.path) { try rejectSymbolicLink(exports) }
        else { try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let assetID = UUID()
        let relativePath = "exports/\(assetID.uuidString).\(preset.fileExtension)"
        let destination = directory.appendingPathComponent(relativePath)
        let byteSize = (try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let asset = RecordingAsset(id: assetID, relativePath: relativePath, container: preset.container, codec: preset.codec,
                                   sampleRate: 48_000, channelCount: 2,
                                   decodedFrameCount: frames, duration: Double(frames) / 48_000,
                                   peak: peak, byteSize: byteSize, validationState: .verified, provenance: provenance)
        let pending = PendingExport(sessionID: sessionID, asset: asset, temporaryName: temporaryURL.lastPathComponent, purpose: purpose)
        try pending.validate()
        let journal = pendingExportURL(sessionID)
        guard !FileManager.default.fileExists(atPath: journal.path) else {
            throw RecorderFailure("An earlier export is awaiting recovery. Recover it before exporting again.")
        }
        try encoder.encode(pending).write(to: journal, options: .atomic)
        try synchronizeFileAndDirectory(journal, directory: directory)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try synchronizeFileAndDirectory(destination, directory: exports)
        return try finishPendingExport(pending)
    }
    public func pendingExportURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("pending-export.json") }
    public func pendingRenderURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("render-job.json") }
    public func savePendingRender(_ job: PendingRenderJob) throws {
        lock.lock(); defer { lock.unlock() }
        try job.validate()
        let owner = try load(job.ownerID)
        if job.request.purpose == .clip || job.request.purpose == .cleanedCopy {
            guard owner.status == .pendingRender, owner.assets.isEmpty,
                  owner.derivation?.parentSessionID == job.request.sessionID else {
                throw RecorderFailure("The derived recording no longer matches its render job.")
            }
        }
        let url = pendingRenderURL(job.ownerID)
        if FileManager.default.fileExists(atPath: url.path) { try rejectSymbolicLink(url) }
        try encoder.encode(job).write(to: url, options: .atomic)
        try synchronizeFileAndDirectory(url, directory: directory(for: job.ownerID))
    }
    public func pendingRender(_ id: UUID) throws -> PendingRenderJob? {
        lock.lock(); defer { lock.unlock() }
        try rejectSymbolicLink(directory(for: id))
        let url = pendingRenderURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(url)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 64_000 else { throw RecorderFailure("The render journal is too large.") }
        let job = try decoder.decode(PendingRenderJob.self, from: Data(contentsOf: url))
        try job.validate()
        guard job.ownerID == id else { throw RecorderFailure("The render journal belongs to another recording.") }
        return job
    }
    /// Removes only intermediate paths explicitly owned by a validated job, never source or saved audio.
    public func cleanRenderIntermediates(_ job: PendingRenderJob) throws {
        lock.lock(); defer { lock.unlock() }
        try job.validate(); _ = try load(job.ownerID)
        guard try pendingExport(job.ownerID) == nil else { return }
        for name in [job.workName, job.temporaryName].compactMap({ $0 }) {
            let url = directory(for: job.ownerID).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try rejectSymbolicLink(url); try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func clearPendingRender(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if let _ = try pendingRender(id) {
            try FileManager.default.removeItem(at: pendingRenderURL(id))
            // Persist intent removal before the asset journal can be removed.
            try synchronizeFileAndDirectory(directory(for: id).appendingPathComponent("session.json"), directory: directory(for: id))
        }
    }
    public func pendingExport(_ id: UUID) throws -> PendingExport? {
        lock.lock(); defer { lock.unlock() }
        try rejectSymbolicLink(directory(for: id))
        let url = pendingExportURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(url)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 64_000 else {
            throw RecorderFailure("The pending export journal is too large.")
        }
        let pending = try decoder.decode(PendingExport.self, from: Data(contentsOf: url))
        try pending.validate()
        guard pending.sessionID == id else { throw RecorderFailure("The pending export belongs to a different recording.") }
        return pending
    }
    /// The caller must fully decode/validate this file again before finishing recovery.
    public func pendingAudioURL(_ pending: PendingExport) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try pending.validate()
        let session = try load(pending.sessionID)
        let destination = directory(for: session.id).appendingPathComponent(pending.asset.relativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try assetURL(session, asset: pending.asset)
        }
        let temporary = directory(for: session.id).appendingPathComponent(pending.temporaryName)
        try rejectSymbolicLink(temporary)
        guard try temporary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecorderFailure("The pending audio is not a regular file.")
        }
        return temporary
    }
    public func finishPendingExport(_ pending: PendingExport) throws -> RecordingSession {
        lock.lock(); defer { lock.unlock() }
        try pending.validate()
        guard try pendingExport(pending.sessionID)?.asset == pending.asset else {
            throw RecorderFailure("The pending export changed before it could be committed.")
        }
        var saved = try load(pending.sessionID)
        let asset = pending.asset
        let destination = directory(for: saved.id).appendingPathComponent(asset.relativePath)
        let source = try pendingAudioURL(pending)
        try rejectSymbolicLink(destination.deletingLastPathComponent())
        if source != destination { try FileManager.default.moveItem(at: source, to: destination) }
        _ = try assetURL(saved, asset: asset)
        try synchronizeFileAndDirectory(destination, directory: destination.deletingLastPathComponent())
        if !saved.assets.contains(where: { $0.id == asset.id }) {
            saved.assets.append(asset)
        }
        if pending.purpose != .additional {
            saved.primaryAssetID = asset.id
            saved.status = (saved.kind != .capture || saved.captureCompleted) && saved.issue == nil ? .ready : .partial
        }
        try save(saved)
        // Only the generated journal is removed, after the asset and metadata are durable.
        // If cleanup fails, recovery recognizes the same asset ID and is idempotent.
        // Keep the asset journal until render intent is cleared, avoiding a duplicate render
        // if a crash occurs after manifest commit but before journal cleanup.
        do {
            try clearPendingRender(saved.id)
            try FileManager.default.removeItem(at: pendingExportURL(saved.id))
        } catch { /* Both journals can safely be retried against the same asset ID. */ }
        // Source CAF segments remain available for later exports, trimming, and recovery.
        return saved
    }
    public func availableBytes() throws -> Int64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
    }
    public func checkedAudioURL(_ session: RecordingSession, segment: RecordingSegment, microphone: Bool) throws -> URL {
        try session.validate()
        try rejectSymbolicLink(directory(for: session.id))
        let url = audioURL(session.id, segment: segment.index, microphone: microphone)
        try rejectSymbolicLink(url)
        return url
    }
    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw RecorderFailure("A recording file was replaced by a symbolic link.") }
    }

    private func normalizeTags(_ tags: [String]) throws -> [String] {
        try LibraryRules.normalizedTags(tags.joined(separator: ","))
    }
    private func preserveV1ManifestBeforeMigration(at manifest: URL, in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        try rejectSymbolicLink(manifest)
        let backup = directory.appendingPathComponent("session-v1.backup.json")
        if FileManager.default.fileExists(atPath: backup.path) { return }
        let data = try Data(contentsOf: manifest)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? NSNumber)?.intValue ?? 1 == 1 else { return }
        try data.write(to: backup, options: .atomic)
        try synchronizeFileAndDirectory(backup, directory: directory)
    }
}
