import AudioTransport
import Foundation
import RecorderCore

public struct CaptureOptions: Sendable {
    public let includeMicrophone: Bool
    public let microphoneID: UInt32?
    public let maximumDuration: TimeInterval?
    public init(includeMicrophone: Bool, microphoneID: UInt32? = nil, maximumDuration: TimeInterval? = nil) {
        self.includeMicrophone = includeMicrophone; self.microphoneID = microphoneID
        self.maximumDuration = maximumDuration
    }
}
public struct CaptureMeter: Sendable {
    public let elapsed: Double
    public let system: Float
    public let microphone: Float
    public let sampleRate: Double
    public init(elapsed: Double, system: Float, microphone: Float, sampleRate: Double) {
        self.elapsed = elapsed; self.system = system; self.microphone = microphone; self.sampleRate = sampleRate
    }
}
public enum CaptureEvent: Sendable {
    case meter(CaptureMeter)
    case stopRequested(String?)
}
public protocol Capturing: Sendable {
    func start(session: RecordingSession, options: CaptureOptions, event: @escaping @Sendable (CaptureEvent) -> Void) async throws
    func stop(reason: String?) async throws -> RecordingSession
    func pause() async throws -> CaptureSnapshot
    func resume() async throws -> CaptureSnapshot
}

public struct CaptureSnapshot: Sendable {
    public let session: RecordingSession
    public let recordedFrames: Int64
    public init(session: RecordingSession, recordedFrames: Int64) { self.session = session; self.recordedFrames = recordedFrames }
}

/// Sole owner of graph/writer state. No mutable property is accessed outside `queue`.
public final class CaptureService: Capturing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "recorder.capture-control", qos: .userInitiated)
    private let store: SessionStore
    private var graph: (any CaptureGraphControlling)?
    private var session: RecordingSession?
    private var systemWriter: (any CaptureWriting)?
    private var microphoneWriter: (any CaptureWriting)?
    private var timer: DispatchSourceTimer?
    private var scratch = [Float](repeating: 0, count: 4096 * 4)
    private var acceptedFrames: Int64 = 0
    private var startedAt: Double = 0
    private var lastDelivery: Double = 0
    private var lastConfigurationCheck: Double = 0
    private var previousFrames: UInt64 = 0
    private var stopRequested = false
    private var captureIssue: String?
    private var maximumFrames: Int64?
    private var microphoneUID: String?
    private var options: CaptureOptions?
    private enum Lifecycle { case idle, recording, pausing, paused, resuming, finished }
    private var lifecycle: Lifecycle = .idle
    private var generation = UUID()
    private let graphFactory: @Sendable (CaptureOptions, String?) throws -> any CaptureGraphControlling
    private let writerFactory: @Sendable (URL, Double, UInt32) throws -> any CaptureWriting
    private let capacity: @Sendable () throws -> Int64
    private var event: (@Sendable (CaptureEvent) -> Void)?

    public convenience init(store: SessionStore) {
        self.init(store: store, graphFactory: { options, uid in
            var id = options.microphoneID
            if let uid {
                guard let device = try AudioDevices.microphones().first(where: { $0.uid == uid }) else {
                    throw RecorderFailure("The original microphone is unavailable. Start a new recording after reconnecting it.")
                }
                id = device.id
            }
            return try CaptureGraph(includeMicrophone: options.includeMicrophone, microphoneID: id)
        })
    }
    init(store: SessionStore,
         graphFactory: @escaping @Sendable (CaptureOptions, String?) throws -> any CaptureGraphControlling,
         writerFactory: @escaping @Sendable (URL, Double, UInt32) throws -> any CaptureWriting = { try AudioFileWriter(url: $0, sampleRate: $1, channels: $2) },
         capacity: (@Sendable () throws -> Int64)? = nil) {
        self.store = store; self.graphFactory = graphFactory; self.writerFactory = writerFactory
        self.capacity = capacity ?? { try store.availableBytes() }
    }

    public func start(session: RecordingSession, options: CaptureOptions,
                      event: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.graph == nil, self.lifecycle == .idle || self.lifecycle == .finished else {
                    continuation.resume(throwing: RecorderFailure("An audio device is still active. Stop recording, or restart the app if the previous device could not be released."))
                    return
                }
                do {
                    self.session = session; self.event = event; self.captureIssue = nil
                    self.acceptedFrames = 0; self.previousFrames = 0; self.stopRequested = false
                    self.lifecycle = .resuming; self.options = options
                    let graph = try self.graphFactory(options, nil)
                    self.graph = graph
                    self.microphoneUID = graph.microphoneUID
                    self.maximumFrames = try options.maximumDuration.map { try RecordingLimits.frameCount(seconds: $0, sampleRate: graph.sampleRate) }
                    self.session?.sampleRate = graph.sampleRate
                    self.session?.microphoneChannels = graph.microphoneChannels
                    guard RecordingLimits.hasRecordingHeadroom(available: try self.capacity(), sampleRate: graph.sampleRate,
                                                                microphoneChannels: graph.microphoneChannels) else {
                        throw RecorderFailure("There is not enough free disk space to start safely. Free some space and try again.")
                    }
                    self.session?.status = .recording
                    try self.store.save(self.session!)
                    try graph.start()
                    self.lifecycle = .recording
                    self.startTimer()
                    continuation.resume()
                } catch {
                    self.captureIssue = error.localizedDescription
                    _ = try? self.finish(reason: error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    public func stop(reason: String?) async throws -> RecordingSession {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.finish(reason: reason)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func pause() async throws -> CaptureSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.lifecycle == .recording else {
                    continuation.resume(throwing: RecorderFailure("Only a recording can be paused.")); return
                }
                self.lifecycle = .pausing
                self.cancelTimer()
                do {
                    if let issue = self.quiesce() { throw RecorderFailure(issue) }
                    guard var current = self.session else { throw RecorderFailure("No recording is active.") }
                    current.status = .paused; current.captureCompleted = false
                    try self.store.save(current)
                    self.session = current; self.lifecycle = .paused
                    continuation.resume(returning: CaptureSnapshot(session: current, recordedFrames: self.acceptedFrames))
                } catch {
                    _ = try? self.finish(reason: error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    public func resume() async throws -> CaptureSnapshot {
        try Task.checkCancellation()
        let snapshot: CaptureSnapshot = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.lifecycle == .paused, let options = self.options, let original = self.session else {
                    continuation.resume(throwing: RecorderFailure("Only a paused recording can be resumed.")); return
                }
                self.lifecycle = .resuming
                do {
                    let graph = try self.graphFactory(options, self.microphoneUID)
                    self.graph = graph
                    guard graph.sampleRate == original.sampleRate, graph.microphoneChannels == original.microphoneChannels,
                          graph.microphoneUID == self.microphoneUID else {
                        throw RecorderFailure("The recording device or audio format changed. The existing audio is kept; start a new recording.")
                    }
                    guard RecordingLimits.hasRecordingHeadroom(available: try self.capacity(), sampleRate: graph.sampleRate, microphoneChannels: graph.microphoneChannels) else {
                        throw RecorderFailure("There is not enough disk space to resume safely.")
                    }
                    self.session?.status = .recording
                    try self.store.save(self.session!)
                    try graph.start()
                    self.lifecycle = .recording; self.previousFrames = 0
                    self.startTimer()
                    continuation.resume(returning: CaptureSnapshot(session: self.session!, recordedFrames: self.acceptedFrames))
                } catch {
                    _ = try? self.finish(reason: error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
        if Task.isCancelled {
            _ = try? await stop(reason: "Resuming was cancelled. The available audio is kept.")
            throw CancellationError()
        }
        return snapshot
    }
    private func startTimer() {
        cancelTimer()
        let token = generation
        startedAt = ProcessInfo.processInfo.systemUptime
        lastDelivery = startedAt; lastConfigurationCheck = startedAt
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == token, self.lifecycle == .recording else { return }
            self.tick()
        }
        self.timer = timer; timer.resume()
    }
    private func cancelTimer() { generation = UUID(); timer?.cancel(); timer = nil }
    private func tick() {
        guard lifecycle == .recording, let graph, let transport = graph.transport, let session else { return }
        do {
            try drain()
            let stats = recorder_transport_stats(transport)
            let now = ProcessInfo.processInfo.systemUptime
            if stats.accepted_frames != previousFrames { previousFrames = stats.accepted_frames; lastDelivery = now }
            if stats.fault != 0 { throw RecorderFailure(Self.faultMessage(stats.fault)) }
            if now - lastDelivery > 3 {
                throw RecorderFailure("No audio data is arriving. Check System Audio Recording permission and your devices. Any received audio has been kept.")
            }
            if now - lastConfigurationCheck >= 1 {
                try graph.checkConfiguration()
                guard RecordingLimits.hasRecordingHeadroom(available: try capacity(), sampleRate: graph.sampleRate,
                                                            microphoneChannels: graph.microphoneChannels) else {
                    throw RecorderFailure("Recording stopped because disk space is low. Free some space before saving the recording.")
                }
                lastConfigurationCheck = now
            }
            event?(.meter(CaptureMeter(elapsed: Double(acceptedFrames) / session.sampleRate,
                                      system: stats.system_peak, microphone: stats.microphone_peak, sampleRate: session.sampleRate)))
            if let maximumFrames, acceptedFrames >= maximumFrames { requestStop(nil) }
        } catch { requestStop(error.localizedDescription) }
    }
    private func requestStop(_ reason: String?) {
        guard !stopRequested else { return }
        stopRequested = true; captureIssue = reason
        if let transport = graph?.transport { recorder_transport_stop(transport) }
        event?(.stopRequested(reason))
    }
    private func drain() throws {
        guard let graph, let transport = graph.transport else { return }
        while true {
            let frames = scratch.withUnsafeMutableBufferPointer { recorder_transport_read(transport, $0.baseAddress, 4096) }
            if frames == 0 { break }
            var offset = 0
            while offset < Int(frames) {
                let remaining = maximumFrames.map { max(0, $0 - acceptedFrames) } ?? Int64.max
                if remaining == 0 { requestStop(nil); return }
                if systemWriter == nil { try openSegment() }
                let segmentLimit = Int64(graph.sampleRate * 30)
                let written = systemWriter?.writtenFrames ?? 0
                let count = min(Int(frames) - offset, Int(min(segmentLimit - written, remaining)))
                let channels = 2 + graph.microphoneChannels
                var system = [Float](repeating: 0, count: count * 2)
                var microphone = [Float](repeating: 0, count: count * graph.microphoneChannels)
                for frame in 0..<count {
                    let base = (offset + frame) * channels
                    system[frame * 2] = scratch[base]; system[frame * 2 + 1] = scratch[base + 1]
                    for channel in 0..<graph.microphoneChannels { microphone[frame * graph.microphoneChannels + channel] = scratch[base + 2 + channel] }
                }
                try system.withUnsafeBufferPointer { try systemWriter?.write($0.baseAddress!, frames: UInt32(count)) }
                if graph.microphoneChannels > 0 {
                    try microphone.withUnsafeBufferPointer { try microphoneWriter?.write($0.baseAddress!, frames: UInt32(count)) }
                }
                acceptedFrames += Int64(count); offset += count
                if systemWriter?.writtenFrames == segmentLimit { try closeSegment() }
            }
        }
    }
    private func openSegment() throws {
        guard var current = session else { throw RecorderFailure("No recording session is active.") }
        let segment = RecordingSegment(index: current.segments.count, startFrame: acceptedFrames)
        current.segments.append(segment)
        // The journal names files before they are created; unfinished files are discoverable after a crash.
        try store.save(current); session = current
        systemWriter = try writerFactory(store.audioURL(current.id, segment: segment.index), current.sampleRate, 2)
        if current.microphoneChannels > 0 {
            microphoneWriter = try writerFactory(store.audioURL(current.id, segment: segment.index, microphone: true),
                                                  current.sampleRate, UInt32(current.microphoneChannels))
        }
    }
    private func closeSegment() throws {
        guard systemWriter != nil || microphoneWriter != nil else { return }
        let frames = max(systemWriter?.writtenFrames ?? 0, microphoneWriter?.writtenFrames ?? 0)
        var problem: Error?
        do { try systemWriter?.close() } catch { problem = error }
        do { try microphoneWriter?.close() } catch { problem = problem ?? error }
        systemWriter = nil; microphoneWriter = nil
        if let index = session?.segments.indices.last {
            session?.segments[index].frames = frames
            session?.segments[index].finalized = problem == nil
        }
        if let problem { throw problem }
        if let session { try store.save(session) }
    }
    private func quiesce() -> String? {
        cancelTimer()
        var issue = captureIssue
        do { try graph?.detach() } catch { issue = issue ?? error.localizedDescription }
        if let transport = graph?.transport {
            let stats = recorder_transport_stats(transport)
            if stats.fault != 0 { issue = issue ?? Self.faultMessage(stats.fault) }
        }
        do { try drain() } catch { issue = issue ?? error.localizedDescription }
        do { try closeSegment() } catch { issue = issue ?? error.localizedDescription }
        do { try graph?.close(); graph = nil } catch { issue = issue ?? error.localizedDescription }
        return issue
    }
    private func finish(reason: String?) throws -> RecordingSession {
        if lifecycle == .finished, graph == nil, let session { try store.save(session); return session }
        let teardownIssue = quiesce()
        var issue = captureIssue ?? reason ?? teardownIssue
        guard var current = session else { throw RecorderFailure("There is no recording to finish.") }
        if acceptedFrames == 0 { issue = issue ?? "No audio was captured. Check recording permission and try again." }
        current.captureCompleted = issue == nil
        current.issue = issue
        current.status = issue == nil ? .recorded : .interrupted
        session = current; event = nil; lifecycle = .finished
        try store.save(current)
        return current
    }
    static func faultMessage(_ fault: UInt32) -> String {
        switch fault {
        case 1: "Recording stopped because the disk writer could not keep up. The audio captured before the interruption has been kept."
        case 2: "The audio buffer layout changed. The available recording has been kept."
        case 3: "The audio timeline was interrupted. The available recording has been kept."
        default: "The audio device delivered invalid samples. The available recording has been kept."
        }
    }
}
