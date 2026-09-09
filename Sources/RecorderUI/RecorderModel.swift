import AppKit
import AVFoundation
import Combine
import RecorderAudio
import RecorderCore
import UniformTypeIdentifiers

@MainActor
public final class RecorderModel: ObservableObject {
    @Published public private(set) var phase: RecorderPhase = .idle
    @Published private(set) var microphones: [MicrophoneDevice] = []
    @Published var includeMicrophone = false
    @Published var microphoneID: UInt32 = 0
    @Published var maximumMinutes = ""
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var captureSampleRate: Double = 0
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var message = "Record your Mac’s audio in stereo. Everything stays on your Mac."
    @Published private(set) var errorMessage: String?
    @Published private(set) var isCopying = false
    @Published private(set) var deletionReservationID: UUID?
    @Published private(set) var isInitializing = true
    @Published private(set) var isShuttingDown = false
    let store: SessionStore
    let library: RecordingLibrary
    let playback: PlaybackController
    let workflow: RecordingWorkflow
    private let capture: any Capturing
    private let exporter: any AudioExporting
    private let trashService: any TrashService
    private var operation: Task<Void, Never>?
    private var activeID: UUID?
    private var exportID: UUID?
    private var copyOperation: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var metadataOperation: Task<RecordingSession, Error>?
    private var trashOperation: Task<Void, Error>?
    private var savePanel: NSSavePanel?
    private let preferences: UserDefaults
    private var deletionInProgress = false
    private enum StopIntent { case requested(String?) }
    private var pendingStop: StopIntent?
    var sessions: [RecordingSession] { library.filteredSessions }
    var totalSessions: Int { library.sessions.count }
    var unreadableSessions: Int { library.unreadableSessions }
    var selectedID: UUID? { get { library.selectedID } set { library.select(newValue) } }
    var selectedSession: RecordingSession? { sessions.first { $0.id == selectedID } }
    var playingID: UUID? { playback.activeID }
    var canWorkWithFiles: Bool {
        phase.canStart && activeID == nil && !isCopying && deletionReservationID == nil &&
        !library.isMutating && !library.isRefreshing && !isInitializing && !isShuttingDown
        && !workflow.isBusy && !workflow.isEditing && !workflow.isLoading
    }
    var canMutateLibrary: Bool { canWorkWithFiles && !library.isRefreshing && !library.isMutating }
    var canDeleteRecording: Bool { canMutateLibrary && !deletionInProgress }

    public init(store: SessionStore, capture: (any Capturing)? = nil, exporter: (any AudioExporting)? = nil,
         trashService: any TrashService = FoundationTrashService(), preferences: UserDefaults = .standard, observeSleep: Bool = true) {
        self.store = store
        self.library = RecordingLibrary(store: store)
        self.playback = PlaybackController(preferences: preferences)
        self.workflow = RecordingWorkflow(store: store)
        self.capture = capture ?? CaptureService(store: store)
        self.exporter = exporter ?? AudioExporter(store: store)
        self.trashService = trashService
        self.preferences = preferences
        includeMicrophone = preferences.bool(forKey: "includeMicrophone")
        maximumMinutes = preferences.string(forKey: "maximumMinutes") ?? ""
        library.onSnapshot = { [weak self] in self?.reconcilePlayback() }
        workflow.stopPlayback = { [weak self] in self?.stopPlayback() }
        workflow.playPreview = { [weak self] result in
            self?.playback.start(id: result.asset.id, title: "Audio preview", url: result.url)
        }
        workflow.libraryChanged = { [weak self] in self?.refresh() }
        library.refresh(recover: true, completion: { [weak self] in
            Task { @MainActor in
                await self?.workflow.initialization?.value
                self?.isInitializing = false
            }
        },
                        onFailure: { [weak self] in self?.errorMessage = $0 })
        refreshDevices()
        if observeSleep {
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                        object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(reason: "Your Mac went to sleep. The available recording has been kept.") }
            }
        }
    }
    func refresh() {
        // A filesystem scan holds the store lock; never compete with the capture writer.
        guard !isInitializing, !isShuttingDown, phase.canStart, !workflow.isEditing, !workflow.isBusy else { return }
        library.refresh(onFailure: { [weak self] message in
            self?.errorMessage = message
        })
    }
    private func reconcilePlayback() {
        workflow.updateDeliveries(library.pendingDeliveries, unreadable: library.hasUnreadableDeliveries)
        guard let id = playback.activeID else { return }
        guard let session = library.sessions.first(where: { $0.id == id }), !library.missingAssets.contains(id) else {
            stopPlayback(); return
        }
        playback.updateTitle(session.title)
    }
    func refreshDevices() {
        do { microphones = try AudioDevices.microphones() }
        catch { microphones = [] }
    }
    func select(_ session: RecordingSession) { selectedID = session.id }
    func start() {
        guard canWorkWithFiles else { return }
        let duration: Double?
        do { duration = try RecordingLimits.duration(minutes: maximumMinutes) }
        catch { failOperation(error); return }
        stopPlayback()
        errorMessage = nil; elapsed = 0; systemLevel = 0; microphoneLevel = 0
        exportProgress = 0; phase = .preparing
        message = includeMicrophone ? "Checking microphone access and preparing audio capture…" : "Preparing system audio capture…"
        let options = CaptureOptions(includeMicrophone: includeMicrophone, microphoneID: microphoneID == 0 ? nil : microphoneID,
                                     maximumDuration: duration)
        preferences.set(includeMicrophone, forKey: "includeMicrophone")
        preferences.set(maximumMinutes, forKey: "maximumMinutes")
        operation = Task {
            do {
                if options.includeMicrophone {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    guard allowed else {
                        throw RecorderFailure("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone, or turn off Include microphone.")
                    }
                }
                try Task.checkCancellation()
                var session = try store.create()
                session.captureExportPresetID = workflow.settings.defaultPreset.rawValue
                try store.save(session)
                activeID = session.id; selectedID = session.id
                let sessionID = session.id
                try await capture.start(session: session, options: options) { [weak self] event in
                    Task { @MainActor in self?.receive(event, sessionID: sessionID) }
                }
                if Task.isCancelled {
                    _ = try? await capture.stop(reason: "Recording setup was cancelled.")
                    activeID = nil; phase = .idle; refresh(); return
                }
                phase = .recording
                message = options.includeMicrophone ? "Capturing system audio and microphone. Source audio is saved in recoverable segments." : "Capturing system audio in stereo. Source audio is saved in recoverable segments."
                refresh()
            } catch is CancellationError {
                activeID = nil; phase = .idle; message = "Recording setup cancelled."; refresh()
            } catch {
                activeID = nil; failOperation(error); refresh()
            }
        }
    }
    func stop(reason: String? = nil) {
        if phase == .pausing || phase == .resuming { pendingStop = .requested(reason); return }
        guard phase == .recording || phase == .paused else { return }
        phase = .stopping; message = "Closing audio files safely…"
        operation = Task {
            do {
                let session = try await capture.stop(reason: reason)
                activeID = nil; selectedID = session.id
                systemLevel = 0; microphoneLevel = 0; refresh()
                if session.captureCompleted {
                    await save(session)
                } else {
                    phase = .idle
                    errorMessage = session.issue
                    message = "Recording interrupted. Recover the available audio from the recordings list."
                }
            } catch { activeID = nil; failOperation(error); refresh() }
        }
    }
    func toggleCapturePause() {
        guard phase == .recording || phase == .paused else { return }
        let resuming = phase == .paused
        phase = resuming ? .resuming : .pausing
        message = resuming ? "Checking the original devices and resuming capture…" : "Closing this audio interval safely…"
        operation = Task {
            do {
                let snapshot = try await (resuming ? capture.resume() : capture.pause())
                elapsed = Double(snapshot.recordedFrames) / snapshot.session.sampleRate
                phase = resuming ? .recording : .paused
                systemLevel = 0; microphoneLevel = 0
                message = resuming ? "Recording continues. Paused time is excluded." : "Capture is stopped. Resume to continue this recording; paused time is excluded."
            } catch {
                activeID = nil; failOperation(error); refresh()
            }
            if case let .requested(reason) = pendingStop {
                pendingStop = nil; stop(reason: reason)
            }
        }
    }
    func recover(_ session: RecordingSession) {
        guard canWorkWithFiles, session.canExport || library.pendingExports.contains(session.id) else { return }
        stopPlayback(); selectedID = session.id; phase = .exporting
        operation = Task { await save(session) }
    }
    private func save(_ session: RecordingSession) async {
        let identifier = UUID()
        exportID = identifier
        defer { exportID = nil }
        phase = .exporting; exportProgress = 0; errorMessage = nil
        message = session.captureCompleted ? "Checking source audio, encoding stereo, and validating the saved file…" : "Recovering available audio. Missing source sections may be silent."
        do {
            let saved = try await exporter.export(session) { [weak self] fraction in
                Task { @MainActor in
                    guard self?.phase == .exporting, self?.exportID == identifier else { return }
                    self?.exportProgress = min(1, max(0, fraction))
                }
            }
            await workflow.deliverAutomatically(saved)
            phase = .idle
            message = saved.status == .partial ? "Partial recording saved. The original source files are also kept." : "Recording saved and checked. Play it here or save a copy."
            selectedID = saved.id
        } catch is CancellationError {
            phase = .idle; message = "Saving cancelled. The original audio is kept; you can retry at any time."
        } catch { failOperation(error) }
        refresh()
    }
    func cancelExport() {
        guard phase == .exporting else { return }
        operation?.cancel(); message = "Cancelling safely. Source audio will be kept…"
    }
    private func receive(_ event: CaptureEvent, sessionID: UUID) {
        guard activeID == sessionID else { return }
        switch event {
        case let .meter(meter):
            guard phase == .recording || phase == .preparing else { return }
            elapsed = meter.elapsed; systemLevel = meter.system; microphoneLevel = meter.microphone
            captureSampleRate = meter.sampleRate
        case let .stopRequested(reason):
            // Setup can complete just after the first callback. Defer until the start operation sets its final state.
            if phase == .preparing {
                Task { [weak self] in
                    await self?.operation?.value
                    self?.stop(reason: reason)
                }
            } else { stop(reason: reason) }
        }
    }
    func togglePlayback(_ session: RecordingSession) {
        guard canWorkWithFiles, session.status.hasExport else { return }
        do {
            playback.toggle(id: session.id, title: session.title, url: try store.primaryAssetURL(session))
        } catch { playback.fail(error, id: session.id, title: session.title) }
    }
    public func toggleActivePlayback() -> Bool {
        guard canWorkWithFiles, playback.isActive, playback.state != .failed else { return false }
        if playback.state == .playing { playback.pause() } else { playback.play() }
        return true
    }
    func playbackCommand(_ command: (PlaybackController) -> Void) {
        guard canWorkWithFiles else { return }
        command(playback)
    }
    func stopPlayback() {
        playback.release()
    }
    func reveal(_ session: RecordingSession) {
        do {
            let url = session.status.hasExport ? try store.primaryAssetURL(session) : store.directory(for: session.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { show(error) }
    }
    func saveCopy(_ session: RecordingSession, asset requestedAsset: RecordingAsset? = nil) {
        guard canWorkWithFiles, session.status.hasExport else { return }
        guard let asset = requestedAsset ?? session.primaryAsset, session.assets.contains(where: { $0.id == asset.id }) else { return }
        stopPlayback()
        isCopying = true
        let panel = NSSavePanel()
        savePanel = panel
        panel.allowedContentTypes = [UTType(filenameExtension: asset.container.fileExtension) ?? .audio]
        panel.nameFieldStringValue = ((try? FilenamePattern.expand("{title}", session: session)) ?? "Recording") + "." + asset.container.fileExtension
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.savePanel = nil
                guard !self.isShuttingDown else { self.isCopying = false; return }
                guard response == .OK, let destination = panel.url else { self.isCopying = false; return }
                self.message = "Saving a copy…"
                self.copyOperation = Task {
                    defer { self.isCopying = false }
                    do {
                        let current = try self.store.load(session.id)
                        guard let savedAsset = current.assets.first(where: { $0.id == asset.id }) else { throw RecorderFailure("The selected export is no longer available.") }
                        let source = try self.store.assetURL(current, asset: savedAsset)
                        try await Task.detached(priority: .userInitiated) {
                            try RecordingCopy.save(source: source, destination: destination)
                        }.value
                        self.message = "A copy was saved to \(destination.lastPathComponent)."
                    } catch { self.show(error) }
                }
            }
        }
    }
    func saveLibraryDetails(_ session: RecordingSession, title: String, tagsText: String) async throws {
        guard canMutateLibrary, library.beginMutation() else { throw RecorderFailure("Finish the current recording task before editing its details.") }
        defer { metadataOperation = nil; library.endMutation(); refresh() }
        let tags = try LibraryRules.normalizedTags(tagsText)
        let task = Task.detached(priority: .userInitiated) { [store] in
            try store.updateLibraryMetadata(id: session.id, title: title == session.title ? nil : title,
                                            tags: tags == session.tags ? nil : tags)
        }
        metadataOperation = task
        let saved = try await task.value
        library.replace(saved)
        reconcilePlayback()
    }
    func toggleFavorite(_ session: RecordingSession) {
        guard canMutateLibrary, library.beginMutation() else { return }
        let task = Task.detached(priority: .userInitiated) { [store] in try store.toggleFavorite(id: session.id) }
        metadataOperation = task
        Task {
            defer { metadataOperation = nil; library.endMutation(); refresh() }
            do {
                let saved = try await task.value
                library.replace(saved)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func reserveDeletion(_ session: RecordingSession) -> Bool {
        guard canDeleteRecording, activeID != session.id,
              library.sessions.contains(where: { $0.id == session.id }), library.beginMutation() else { return false }
        deletionReservationID = session.id
        return true
    }
    func cancelDeletion(_ session: RecordingSession) {
        guard deletionReservationID == session.id, !deletionInProgress else { return }
        deletionReservationID = nil
        library.endMutation(); refresh()
    }
    func cancelDeletionReservation() {
        guard !deletionInProgress else { return }
        if deletionReservationID != nil { deletionReservationID = nil; library.endMutation(); refresh() }
    }
    func moveReservedRecordingToTrash(_ session: RecordingSession) async throws {
        guard deletionReservationID == session.id, !deletionInProgress,
              phase.canStart, !isCopying, !isShuttingDown, activeID != session.id else {
            throw RecorderFailure("This recording cannot be moved to Trash while another recording task is active.")
        }
        deletionInProgress = true
        defer { deletionInProgress = false; trashOperation = nil }
        stopPlayback()
        do {
            let task = Task.detached(priority: .userInitiated) { [store, trashService] in
                try store.trashSession(session.id, using: trashService)
            }
            trashOperation = task
            try await task.value
            library.remove(id: session.id)
            deletionReservationID = nil
            library.endMutation(); refresh()
        } catch {
            throw error
        }
    }
    func dismissError() { errorMessage = nil; if phase == .failed { phase = .idle } }
    public func openStorage() { NSWorkspace.shared.open(store.root) }
    public func shutdown() async {
        isShuttingDown = true
        stopPlayback()
        savePanel?.cancel(nil)
        savePanel = nil
        if phase == .preparing { operation?.cancel() }
        if [.recording, .paused, .pausing, .resuming].contains(phase) { stop() }
        // A normal quit awaits safe finalization. Failed exports remain recoverable.
        await operation?.value
        // A transition can serialize a pending stop into a new finalization task.
        await operation?.value
        await copyOperation?.value
        _ = try? await metadataOperation?.value
        _ = try? await trashOperation?.value
        await library.refreshTask?.value
        await workflow.shutdown()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }
    private func failOperation(_ error: Error) {
        show(error)
        phase = .failed; message = "Review the message below. Any source audio already captured is kept."
    }
}
