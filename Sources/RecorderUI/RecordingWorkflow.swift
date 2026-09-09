import AppKit
import Combine
import RecorderAudio
import RecorderCore

/// Owns export settings, one render/delivery job, and one disposable preview.
@MainActor
final class RecordingWorkflow: ObservableObject {
    @Published private(set) var settings = DestinationSettings()
    @Published private(set) var capabilities: [ExportCapability] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isBusy = false
    @Published var isEditing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String?
    @Published private(set) var pendingDeliveries: [DeliveryJob] = []
    let renderer: AudioRenderService
    let destinationStore: ExportDestinationStore
    private let delivery: ExportDeliveryService
    private let store: SessionStore
    private var renderTask: Task<RenderResult, Error>?
    private var deliveryTask: Task<DeliveryJob, Error>?
    private var preview: RenderResult?
    private var generation = UUID()
    private var isShuttingDown = false
    private var settingsTask: Task<Void, Error>?
    private var folderPanel: NSOpenPanel?
    private(set) var initialization: Task<Void, Never>?
    var stopPlayback: () -> Void = {}
    var playPreview: (RenderResult) -> Void = { _ in }
    var libraryChanged: () -> Void = {}

    init(store: SessionStore) {
        self.store = store; renderer = AudioRenderService(store: store)
        destinationStore = ExportDestinationStore(managedRoot: store.root)
        delivery = ExportDeliveryService(store: store, destinations: destinationStore)
        initialization = Task {
            capabilities = await Task.detached(priority: .utility) { ExportCapabilities.cached }.value
            do {
                let destinationStore = destinationStore
                settings = try await Task.detached(priority: .utility) { try destinationStore.load() }.value
                if !isSupported(settings.defaultPreset) {
                    settings.defaultPreset = .balanced
                    message = "The saved default format is unavailable. Balanced AAC is selected; review Export settings."
                }
                await refreshDeliveries()
            } catch { message = "Export settings could not be loaded: \(error.localizedDescription)" }
            isLoading = false
        }
    }
    func isSupported(_ preset: ExportPreset) -> Bool { capabilities.contains { $0.preset == preset && $0.isAvailable } }
    func saveSettings(_ proposed: DestinationSettings) async throws {
        guard !isBusy, !isShuttingDown, isSupported(proposed.defaultPreset) else { throw RecorderFailure("The export settings cannot be saved while busy or with an unavailable format.") }
        isBusy = true; defer { isBusy = false; settingsTask = nil }
        let task = Task.detached(priority: .utility) { [destinationStore] in try destinationStore.save(proposed) }
        settingsTask = task
        try await task.value
        settings = proposed
    }
    func chooseFolder() async throws -> (Data, String)? {
        guard !isShuttingDown, folderPanel == nil else { throw RecorderFailure("The folder picker is unavailable.") }
        let panel = NSOpenPanel()
        folderPanel = panel; defer { folderPanel = nil }
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = "Choose export folder"
        let response = await panel.begin()
        guard !isShuttingDown, response == .OK, let url = panel.url else { return nil }
        let bookmark = try await Task.detached(priority: .utility) { [destinationStore] in try destinationStore.bookmark(for: url) }.value
        return (bookmark, url.path)
    }
    func perform(_ request: RenderRequest, copyToFolder: Bool) async throws -> RenderResult {
        guard !isBusy, !isLoading, !isShuttingDown, isSupported(request.preset) else { throw RecorderFailure("Finish the current task or choose an available export format.") }
        isBusy = true; progress = 0; message = nil
        let token = UUID(); generation = token
        let settingsSnapshot = settings
        stopPlayback(); await removePreview()
        defer { isBusy = false; renderTask = nil; if request.purpose != .preview { libraryChanged() } }
        let task = Task { [renderer] in
            try await renderer.render(request) { [weak self] value in
                Task { @MainActor in if self?.generation == token { self?.progress = value } }
            }
        }
        renderTask = task
        let result = try await task.value
        if request.purpose == .preview {
            guard generation == token else { await discardPreview(result); throw CancellationError() }
            preview = result; playPreview(result)
        } else {
            message = "Saved in the app. The original recording is unchanged."
            if copyToFolder, let session = result.session {
                await copyCommitted(session: session, asset: result.asset, settings: settingsSnapshot)
            }
        }
        return result
    }
    func deliverAutomatically(_ session: RecordingSession) async {
        guard settings.automaticallyCopy, let asset = session.primaryAsset else { return }
        await copyCommitted(session: session, asset: asset, settings: settings)
    }
    private func copyCommitted(session: RecordingSession, asset: RecordingAsset, settings: DestinationSettings) async {
        guard !isShuttingDown else { return }
        let task = Task { [delivery] in try await delivery.deliver(sessionID: session.id, assetID: asset.id, settings: settings) }
        deliveryTask = task
        defer { deliveryTask = nil }
        do {
            let job = try await task.value
            message = "Recording saved in the app; exported copy: \(job.targetName ?? "saved file")."
        } catch {
            message = "Recording saved in the app; external copy failed: \(error.localizedDescription)"
        }
        await refreshDeliveries()
    }
    func retry(_ job: DeliveryJob, useCurrentFolder: Bool = false) async {
        guard !isBusy, !isShuttingDown else { return }
        isBusy = true; stopPlayback()
        defer { isBusy = false; deliveryTask = nil }
        let bookmark = useCurrentFolder ? settings.bookmark : nil
        let task = Task { [delivery] in try await delivery.retry(job, inFolder: bookmark) }
        deliveryTask = task
        do { let saved = try await task.value; message = "Exported copy: \(saved.targetName ?? "saved file")." }
        catch { message = "Recording is still saved in the app; external copy failed: \(error.localizedDescription)" }
        await refreshDeliveries()
    }
    func refreshDeliveries() async {
        do {
            let result = try await Task.detached(priority: .utility) { [store, delivery] in
                try store.list().sessions.flatMap { try delivery.jobs(sessionID: $0.id) }.filter { $0.state != .succeeded }
            }.value
            pendingDeliveries = result
        } catch { message = "Some export-copy journals could not be read: \(error.localizedDescription)" }
    }
    func updateDeliveries(_ jobs: [DeliveryJob], unreadable: Bool) {
        pendingDeliveries = jobs
        if unreadable { message = "Some export-copy journals could not be read. Their files have been kept." }
    }
    func invalidatePreview() {
        generation = UUID(); renderTask?.cancel(); stopPlayback()
        if let previous = preview { preview = nil; Task { await discardPreview(previous) } }
    }
    func cancel() { renderTask?.cancel(); deliveryTask?.cancel() }
    func closeEditor() {
        let wasEditing = isEditing
        isEditing = false; invalidatePreview()
        if wasEditing { libraryChanged() }
    }
    private func removePreview() async {
        if let previous = preview { preview = nil; await discardPreview(previous) }
    }
    private func discardPreview(_ result: RenderResult) async {
        guard let folder = result.previewDirectory,
              folder.deletingLastPathComponent().standardizedFileURL.path == store.root.appendingPathComponent(".previews").standardizedFileURL.path,
              UUID(uuidString: folder.lastPathComponent) != nil else { return }
        _ = await Task.detached(priority: .utility) { [store] in try? store.discardPreviewDirectory(folder) }.value
    }
    func shutdown() async {
        isShuttingDown = true; generation = UUID(); cancel(); stopPlayback()
        folderPanel?.cancel(nil)
        _ = try? await renderTask?.value; _ = try? await deliveryTask?.value
        _ = try? await settingsTask?.value
        await initialization?.value; await removePreview()
    }
}
