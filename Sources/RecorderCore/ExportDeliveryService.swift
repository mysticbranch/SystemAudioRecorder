import CryptoKit
import Darwin
import Foundation

public struct DeliveryJob: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, succeeded, failed }
    public let id: UUID
    public let sessionID: UUID
    public let assetID: UUID
    public var bookmark: Data
    public let basename: String
    public let fileExtension: String
    public let digest: String
    public let byteSize: Int64
    public var targetName: String?
    public var state: State
    public var error: String?
}

public enum AudioFileDigest {
    public static func sha256(_ url: URL, check: () throws -> Void = {}) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try check()
            guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func copyAndSync(source: URL, temporary: URL, check: () throws -> Void = {}) throws {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
        while true {
            try check()
            guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
    }
}

private final class DeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

public final class ExportDeliveryService: Sendable {
    private let store: SessionStore
    private let destinations: ExportDestinationStore
    public init(store: SessionStore, destinations: ExportDestinationStore) { self.store = store; self.destinations = destinations }
    public func deliver(sessionID: UUID, assetID: UUID, settings: DestinationSettings) async throws -> DeliveryJob {
        guard let bookmark = settings.bookmark else { throw RecorderFailure("Choose an export folder first.") }
        let cancellation = DeliveryCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let session = try self.store.load(sessionID)
                guard let asset = session.assets.first(where: { $0.id == assetID }) else { throw RecorderFailure("The requested export is no longer available.") }
                let url = try self.store.assetURL(session, asset: asset)
                let basename = try FilenamePattern.expand(settings.pattern, session: session)
                // Reuse a matching delivery, including a previous publish whose bookkeeping failed.
                if let previous = try self.jobs(sessionID: sessionID).last(where: { $0.assetID == assetID && $0.basename == basename && $0.bookmark == bookmark }) {
                    return try self.perform(previous, cancellation: cancellation)
                }
                let job = DeliveryJob(id: UUID(), sessionID: sessionID, assetID: assetID, bookmark: bookmark,
                    basename: basename, fileExtension: asset.container.fileExtension, digest: try AudioFileDigest.sha256(url, check: cancellation.check),
                    byteSize: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), targetName: nil, state: .pending, error: nil)
                try self.save(job)
                return try self.perform(job, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }
    public func retry(_ original: DeliveryJob, inFolder bookmark: Data? = nil) async throws -> DeliveryJob {
        let cancellation = DeliveryCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                var job = original
                if let bookmark, bookmark != job.bookmark { job.bookmark = bookmark; job.targetName = nil; job.state = .pending }
                return try self.perform(job, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }
    private func directory(_ id: UUID, create: Bool = true) throws -> URL {
        _ = try store.load(id)
        let url = store.directory(for: id).appendingPathComponent(".deliveries", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RecorderFailure("The delivery journal folder is unsafe.") }
        } else if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        return url
    }
    public func jobs(sessionID: UUID) throws -> [DeliveryJob] {
        let folder = try directory(sessionID, create: false)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return nil }
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]).isSymbolicLink != true,
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 1_000_000 else { throw RecorderFailure("A delivery journal is unsafe.") }
            let job = try JSONDecoder().decode(DeliveryJob.self, from: Data(contentsOf: url))
            try validate(job)
            guard job.sessionID == sessionID, job.id.uuidString == url.deletingPathExtension().lastPathComponent else { throw RecorderFailure("A delivery journal has the wrong identity.") }
            return job
        }
    }
    private func validate(_ job: DeliveryJob) throws {
        guard !job.basename.isEmpty, job.basename.utf8.count <= 180, RecordingPath.isSafeRelativePath(job.basename), !job.basename.contains("/"),
              ["m4a", "wav", "flac"].contains(job.fileExtension), job.byteSize > 0, job.byteSize < Int64.max - 1_048_576,
              job.digest.count == 64, job.digest.allSatisfy(\.isHexDigit),
              job.targetName == nil || (RecordingPath.isSafeRelativePath(job.targetName!) && !job.targetName!.contains("/") && job.targetName!.utf8.count <= 240) else {
            throw RecorderFailure("A delivery journal has invalid names or measurements.")
        }
    }
    private func save(_ job: DeliveryJob) throws {
        try validate(job)
        let url = try directory(job.sessionID).appendingPathComponent("\(job.id.uuidString).json")
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func perform(_ original: DeliveryJob, cancellation: DeliveryCancellation) throws -> DeliveryJob {
        var job = original
        do {
            try validate(job); try cancellation.check()
            let resolution = try destinations.resolve(job.bookmark)
            let folder = resolution.url
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            if let refreshed = resolution.refreshedBookmark { job.bookmark = refreshed }
            if let name = job.targetName {
                let existing = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: existing.path),
                   try existing.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                   (try existing.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == job.byteSize,
                   try AudioFileDigest.sha256(existing, check: cancellation.check) == job.digest {
                    job.state = .succeeded; job.error = nil; try save(job); return job
                }
            }
            let session = try store.load(job.sessionID)
            guard let asset = session.assets.first(where: { $0.id == job.assetID }) else { throw RecorderFailure("The internal export is unavailable.") }
            let source = try store.assetURL(session, asset: asset)
            guard try AudioFileDigest.sha256(source, check: cancellation.check) == job.digest else { throw RecorderFailure("The internal export changed after delivery was requested.") }
            let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            guard (free.volumeAvailableCapacityForImportantUsage ?? Int64(free.volumeAvailableCapacity ?? 0)) > job.byteSize + 1_048_576 else { throw RecorderFailure("The export destination does not have enough space.") }
            let temporary = folder.appendingPathComponent(".recording-copy-\(job.id.uuidString)-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try AudioFileDigest.copyAndSync(source: source, temporary: temporary, check: cancellation.check)
            guard try AudioFileDigest.sha256(temporary, check: cancellation.check) == job.digest else { throw RecorderFailure("The copied audio did not match its source.") }
            for suffix in 1...10_000 {
                try cancellation.check()
                let name = job.basename + (suffix == 1 ? "" : "-\(suffix)") + "." + job.fileExtension
                job.targetName = name; job.state = .pending; job.error = nil
                try save(job) // Record candidate before publish so crash recovery can adopt it by hash.
                let destination = folder.appendingPathComponent(name)
                if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                    let fd = open(folder.path, O_RDONLY)
                    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let synced = fsync(fd); let code = errno; close(fd)
                    guard synced == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                    job.state = .succeeded; try save(job); return job
                }
                guard errno == EEXIST else { throw RecorderFailure("The destination could not publish a copy safely (file error \(errno)). Choose another folder.") }
            }
            throw RecorderFailure("Too many files share this name. Choose another filename pattern.")
        } catch {
            job.state = .failed; job.error = error.localizedDescription; try? save(job)
            throw error
        }
    }
}
