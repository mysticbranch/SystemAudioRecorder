import Combine
import Foundation
import RecorderCore

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var unreadableSessions = 0
    @Published private(set) var managedBytes: [UUID: Int64] = [:]
    @Published private(set) var sourceBytes: [UUID: Int64] = [:]
    @Published private(set) var missingAssets: Set<UUID> = []
    @Published private(set) var pendingExports: Set<UUID> = []
    private(set) var pendingDeliveries: [DeliveryJob] = []
    private(set) var hasUnreadableDeliveries = false
    @Published private(set) var filteredSessions: [RecordingSession] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published var selectedID: UUID?
    @Published var searchText = "" { didSet { reconcileSelection() } }
    @Published var favoritesOnly = false { didSet { reconcileSelection() } }
    @Published var selectedTags: Set<String> = [] { didSet { reconcileSelection() } }
    @Published var sort: LibrarySort = .newestFirst { didSet { reconcileSelection() } }

    private let store: SessionStore
    private var refreshGeneration = UUID()
    private(set) var refreshTask: Task<Void, Never>?
    var onSnapshot: (() -> Void)?
    private let loader: @Sendable (Bool) async throws -> LibrarySnapshot

    init(store: SessionStore, loader: (@Sendable (Bool) async throws -> LibrarySnapshot)? = nil) {
        self.store = store
        self.loader = loader ?? { recover in
            try await Task.detached(priority: .utility) { try store.librarySnapshot(recoverInterrupted: recover) }.value
        }
    }

    var query: LibraryQuery {
        LibraryQuery(searchText: searchText, favoritesOnly: favoritesOnly, selectedTags: selectedTags, sort: sort)
    }
    var allTags: [String] {
        var seen = Set<String>()
        return sessions.flatMap(\.tags).filter { seen.insert(LibraryRules.folded($0)).inserted }
            .sorted { LibraryRules.folded($0) < LibraryRules.folded($1) }
    }
    var hasActiveFilters: Bool { !searchText.isEmpty || favoritesOnly || !selectedTags.isEmpty || sort != .newestFirst }

    func refresh(recover: Bool = false, completion: @escaping () -> Void = {}, onFailure: @escaping (String) -> Void = { _ in }) {
        guard !isMutating else { return }
        let generation = UUID()
        refreshGeneration = generation
        isRefreshing = true
        refreshTask = Task {
            let outcome: Result<LibrarySnapshot, Error>
            do { outcome = .success(try await loader(recover)) }
            catch { outcome = .failure(error) }
            guard generation == refreshGeneration else { return }
            isRefreshing = false
            switch outcome {
            case let .success(snapshot):
                sessions = snapshot.sessions
                unreadableSessions = snapshot.unreadable
                managedBytes = snapshot.managedBytes
                sourceBytes = snapshot.sourceBytes
                missingAssets = snapshot.missingAssets
                pendingExports = snapshot.pendingExports
                pendingDeliveries = snapshot.pendingDeliveries
                hasUnreadableDeliveries = snapshot.hasUnreadableDeliveries
                reconcileSelection()
                onSnapshot?()
            case let .failure(error): onFailure(error.localizedDescription)
            }
            completion()
        }
    }

    func select(_ id: UUID?) { selectedID = id; reconcileSelection() }
    func clearFilters() {
        searchText = ""; favoritesOnly = false; selectedTags = []; sort = .newestFirst
    }
    func toggleTag(_ tag: String) {
        let normalized = LibraryRules.folded(tag)
        if let existing = selectedTags.first(where: { LibraryRules.folded($0) == normalized }) { selectedTags.remove(existing) }
        else { selectedTags.insert(tag) }
    }
    func replace(_ session: RecordingSession) {
        invalidateRefresh()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
        reconcileSelection()
    }
    func remove(id: UUID) {
        invalidateRefresh()
        sessions.removeAll { $0.id == id }
        managedBytes[id] = nil
        sourceBytes[id] = nil
        missingAssets.remove(id); pendingExports.remove(id)
        pendingDeliveries.removeAll { $0.sessionID == id }
        onSnapshot?()
        reconcileSelection()
    }
    func beginMutation() -> Bool {
        guard !isMutating else { return false }
        invalidateRefresh()
        isMutating = true
        return true
    }
    func endMutation() { isMutating = false }

    private func invalidateRefresh() {
        refreshGeneration = UUID()
        isRefreshing = false
    }
    private func reconcileSelection() {
        filteredSessions = query.applying(to: sessions)
        if let selectedID, !filteredSessions.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
}
