import SwiftUI
import RecorderCore

public struct ContentView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject private var library: RecordingLibrary
    @ObservedObject private var playback: PlaybackController
    @ObservedObject private var workflow: RecordingWorkflow
    @State private var editingSession: RecordingSession?
    @State private var deletingSession: RecordingSession?
    @State private var renderDraft: RenderDraft?
    @State private var exportSettings = false
    private struct RenderDraft: Identifiable {
        let id = UUID()
        let session: RecordingSession
        let purpose: RenderPurpose
    }

    public init(model: RecorderModel) {
        self.model = model
        _library = ObservedObject(wrappedValue: model.library)
        _playback = ObservedObject(wrappedValue: model.playback)
        _workflow = ObservedObject(wrappedValue: model.workflow)
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Audio Recorder").font(.headline)
                    Text("A little space for what you hear.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("On-device", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    recordingCard
                    if let error = model.errorMessage { errorCard(error) }
                    if let message = workflow.message {
                        Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(workflow.pendingDeliveries) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("External copy pending: \(job.basename)").font(.callout)
                            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            HStack {
                                Button("Retry copy") { Task { if model.canWorkWithFiles { await workflow.retry(job) } } }
                                Button("Retry in selected folder") { Task { if model.canWorkWithFiles { await workflow.retry(job, useCurrentFolder: true) } } }
                                    .disabled(workflow.settings.bookmark == nil)
                            }.disabled(!model.canWorkWithFiles)
                        }
                    }
                    if model.phase.canStart { sourceSettings }
                    if playback.isActive { playbackPanel }
                    recordings
                }
                .padding(28)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack {
                Text("Stereo · Local storage").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export settings") {
                    guard model.canWorkWithFiles else { return }
                    workflow.isEditing = true; model.stopPlayback(); exportSettings = true
                }.font(.caption).disabled(!model.canWorkWithFiles)
                Button("Open recordings folder", action: model.openStorage).buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
        }
        .frame(minWidth: 620, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $renderDraft, onDismiss: { workflow.closeEditor() }) { draft in
            RenderEditorSheet(session: draft.session, purpose: draft.purpose, workflow: workflow)
        }
        .sheet(isPresented: $exportSettings, onDismiss: { workflow.closeEditor() }) {
            ExportSettingsSheet(workflow: workflow)
        }
        .sheet(item: $editingSession) { session in
            RecordingDetailsSheet(session: session, managedBytes: library.managedBytes[session.id], sourceBytes: library.sourceBytes[session.id]) { title, tags in
                try await model.saveLibraryDetails(session, title: title, tagsText: tags)
            }
        }
        .sheet(item: $deletingSession, onDismiss: {
            model.cancelDeletionReservation()
        }) { session in
            DeleteRecordingSheet(session: session, managedBytes: library.managedBytes[session.id]) {
                try await model.moveReservedRecordingToTrash(session)
            } onCancel: {
                model.cancelDeletion(session)
            }
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.phase.title).font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text(model.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 18)
                Image(systemName: model.phase == .recording ? "record.circle.fill" : "waveform")
                    .font(.system(size: 32)).foregroundStyle(model.phase == .recording ? .red : .secondary)
                    .accessibilityHidden(true)
            }
            if [.recording, .pausing, .paused, .resuming, .stopping].contains(model.phase) {
                Text(Self.time(model.elapsed)).font(.system(size: 48, weight: .light, design: .monospaced))
                    .accessibilityLabel("Recorded duration \(Self.time(model.elapsed))")
                VStack(spacing: 12) {
                    LevelMeter(title: "System audio", level: model.systemLevel)
                    if model.includeMicrophone { LevelMeter(title: "Microphone", level: model.microphoneLevel) }
                }
                if model.captureSampleRate > 0 {
                    Text("Capture clock: \(Int(model.captureSampleRate).formatted()) Hz").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.phase == .exporting {
                ProgressView(value: model.exportProgress).accessibilityLabel("Saving recording")
                HStack {
                    Text("\(Int(model.exportProgress * 100))% · Source audio is kept for recovery and future exports.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel saving", action: model.cancelExport)
                }
            } else if [.preparing, .pausing, .resuming, .stopping].contains(model.phase) {
                HStack { ProgressView().controlSize(.small); Text(model.phase.title + "…").foregroundStyle(.secondary) }
            } else {
                HStack {
                    if model.phase == .recording || model.phase == .paused {
                        Button(action: model.toggleCapturePause) {
                            Label(model.phase == .paused ? "Resume" : "Pause", systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                        }
                        Button { model.stop() } label: { Label("Stop and save", systemImage: "stop.fill").padding(.horizontal, 12).padding(.vertical, 5) }
                            .buttonStyle(.borderedProminent).tint(.red).keyboardShortcut("r", modifiers: [.command, .shift])
                    } else {
                        Button(action: model.start) { Label("Start recording", systemImage: "record.circle").padding(.horizontal, 12).padding(.vertical, 5) }
                            .buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: [.command, .shift])
                            .disabled(!model.canWorkWithFiles)
                    }
                    Spacer()
                    Text("⇧⌘R").font(.caption.monospaced()).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.07)))
    }
    private var sourceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording setup").font(.headline)
            HStack {
                Label("System audio", systemImage: "speaker.wave.2").font(.callout)
                Spacer()
                Text("Always included · Stereo").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Include microphone", isOn: $model.includeMicrophone).toggleStyle(.switch)
                .help("Add your voice to the system audio. Microphone access is requested only when this is enabled.")
            if model.includeMicrophone {
                HStack {
                    Picker("Microphone", selection: $model.microphoneID) {
                        Text("System default").tag(UInt32(0))
                        ForEach(model.microphones) { microphone in Text(microphone.name).tag(microphone.id) }
                        if model.microphoneID != 0 && !model.microphones.contains(where: { $0.id == model.microphoneID }) {
                            Text("Selected microphone unavailable").tag(model.microphoneID)
                        }
                    }
                    Button(action: model.refreshDevices) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh microphones")
                }
                Text("Headphones help prevent your microphone from recording the speakers again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stop automatically").font(.callout)
                    Text("Leave blank to record until you stop.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("No limit", text: $model.maximumMinutes).textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("Maximum recording time in minutes")
                Text("minutes").font(.callout).foregroundStyle(.secondary)
            }
            Text("macOS will ask for recording permission on first use. Obtain permission from people you record.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Now playing").font(.headline)
                    Text(playback.title).font(.callout).lineLimit(1)
                }
                Spacer()
                Text("\(Self.time(playback.displayedTime)) / \(Self.time(playback.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if playback.duration > 0 {
                Slider(value: Binding(
                    get: { playback.displayedTime },
                    set: { value in
                        model.playbackCommand {
                            if $0.isScrubbing { $0.updateScrubPosition(value) }
                            else { $0.seek(to: value) }
                        }
                    }
                ), in: 0...playback.duration, onEditingChanged: { editing in
                    model.playbackCommand { if editing { $0.beginScrubbing() } else { $0.endScrubbing() } }
                })
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Self.time(playback.displayedTime)) of \(Self.time(playback.duration))")
            }
            HStack(spacing: 10) {
                Button { model.playbackCommand { $0.skip(by: -10) } } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel("Back 10 seconds").help("Back 10 seconds").disabled(playback.duration == 0)
                Button {
                    _ = model.toggleActivePlayback()
                } label: {
                    Label(playback.state == .playing ? "Pause" : "Play", systemImage: playback.state == .playing ? "pause.fill" : "play.fill")
                }.disabled(playback.state == .failed)
                Button { model.playbackCommand { $0.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(playback.state == .stopped || playback.state == .failed)
                Button { model.playbackCommand { $0.skip(by: 10) } } label: { Image(systemName: "goforward.10") }
                    .accessibilityLabel("Forward 10 seconds").help("Forward 10 seconds").disabled(playback.duration == 0)
                Spacer()
                Picker("Speed", selection: Binding(get: { playback.rate }, set: { value in model.playbackCommand { $0.setRate(value) } })) {
                    ForEach(PlaybackController.supportedRates, id: \.self) { rate in Text("\(rate, specifier: "%g")×").tag(rate) }
                }.frame(width: 115)
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                    Slider(value: Binding(get: { Double(playback.volume) }, set: { value in model.playbackCommand { $0.setVolume(Float(value)) } }), in: 0...1)
                        .frame(width: 95).accessibilityLabel("Playback volume")
                        .accessibilityValue("\(Int(playback.volume * 100)) percent")
                }
            }
            if let error = playback.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .disabled(!model.canWorkWithFiles)
    }
    private var recordings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your recordings").font(.headline)
                Spacer()
                if library.isRefreshing { ProgressView().controlSize(.small) }
                Text("\(model.sessions.count) of \(model.totalSessions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("Search recordings", text: $library.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search recordings by name or tag")
                Button { library.favoritesOnly.toggle() } label: {
                    Image(systemName: library.favoritesOnly ? "star.fill" : "star")
                }.help("Show favorites only")
                Menu {
                    Picker("Sort recordings", selection: $library.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { sort in
                        Text(Self.sortLabel(sort)).tag(sort)
                    }
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh recordings")
            }
            if !library.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(library.allTags, id: \.self) { tag in
                            let selected = library.selectedTags.contains { LibraryRules.folded($0) == LibraryRules.folded(tag) }
                            Button(tag) { library.toggleTag(tag) }
                                .buttonStyle(.bordered)
                                .tint(selected ? .accentColor : .secondary)
                        }
                    }
                }
            }
            if library.hasActiveFilters {
                HStack {
                    Text("Filters are applied.").font(.caption).foregroundStyle(.secondary)
                    Button("Clear filters", action: library.clearFilters).buttonStyle(.link).font(.caption)
                }
            }
            if model.unreadableSessions > 0 {
                Label("\(model.unreadableSessions) recording folder(s) could not be read. The files are still in the recordings folder.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.isInitializing ? "Loading recordings…" : model.totalSessions == 0 ? "Your first recording starts here." : "No recordings match these filters.").font(.callout)
                    Text(model.totalSessions == 0 ? "Saved recordings and interrupted sessions will appear in this list." : "Clear or change the filters to see your recordings.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(28)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.sessions) { session in sessionRow(session) }
                }
            }
        }
    }
    private func sessionRow(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: session.status.hasExport ? "waveform" : "clock.arrow.circlepath")
                    .font(.title3).foregroundStyle(session.status == .interrupted || session.status == .partial ? .orange : .secondary)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.callout.weight(.medium)).lineLimit(2)
                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text("\(session.status.label) · \(Self.time(session.duration)) · \(session.microphoneChannels > 0 ? "System + microphone" : "System audio")")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button { model.toggleFavorite(session) } label: {
                    Image(systemName: session.isFavorite ? "star.fill" : "star")
                }.buttonStyle(.plain).help(session.isFavorite ? "Remove from favorites" : "Add to favorites").disabled(!model.canMutateLibrary)
                Spacer(minLength: 0)
            }
            if !session.tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(session.tags, id: \.self) { tag in
                            Button(tag) { library.toggleTag(tag) }.buttonStyle(.bordered).controlSize(.mini)
                                .fixedSize()
                        }
                    }
                }
            }
            if let bytes = library.managedBytes[session.id] {
                Text("Storage: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · Sources: \(ByteCountFormatter.string(fromByteCount: library.sourceBytes[session.id] ?? 0, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if library.missingAssets.contains(session.id) {
                Text("Saved audio is missing or unavailable. Restore the file and refresh the library.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let issue = session.issue {
                Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 10) {
                if library.pendingExports.contains(session.id) {
                    Button("Finish saving") { model.recover(session) }.disabled(!model.canWorkWithFiles)
                }
                if session.status.hasExport {
                    Button { model.togglePlayback(session) } label: {
                        Label(model.playingID == session.id && playback.state == .playing ? "Pause" : "Play", systemImage: model.playingID == session.id && playback.state == .playing ? "pause.fill" : "play.fill")
                    }.disabled(!model.canWorkWithFiles || library.missingAssets.contains(session.id))
                    Button("Save a copy…") { model.saveCopy(session) }.disabled(!model.canWorkWithFiles || library.missingAssets.contains(session.id))
                    Menu("Tools") {
                        Button("Export format…") { openEditor(session, purpose: .additional) }
                        Button("Trim / Save clip…") { openEditor(session, purpose: .clip) }
                        Button("Clean up audio…") { openEditor(session, purpose: .cleanedCopy) }
                        if session.assets.count > 1 {
                            Divider()
                            ForEach(session.assets.filter { $0.id != session.primaryAssetID }) { asset in
                                Button("Save \(asset.provenance?.preset.title ?? asset.codec.rawValue.uppercased()) copy…") { model.saveCopy(session, asset: asset) }
                            }
                        }
                    }.disabled(!model.canWorkWithFiles || library.missingAssets.contains(session.id))
                } else if session.canExport {
                    Button(session.captureCompleted ? "Save recording" : "Recover audio") { model.recover(session) }
                        .disabled(!model.canWorkWithFiles)
                }
              }
              HStack(spacing: 10) {
                Button("Edit details") { editingSession = session }.disabled(!model.canMutateLibrary)
                Button("Move to Trash…", role: .destructive) {
                    if model.reserveDeletion(session) { deletingSession = session }
                }.disabled(!model.canDeleteRecording)
                Button("Show in Finder") { model.reveal(session) }
              }
            }.controlSize(.small)
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private func openEditor(_ session: RecordingSession, purpose: RenderPurpose) {
        guard model.canWorkWithFiles else { return }
        workflow.isEditing = true; model.stopPlayback()
        renderDraft = RenderDraft(session: session, purpose: purpose)
    }
    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: model.dismissError) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .padding(16).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(seconds, 1_000_000_000))) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
    static func sortLabel(_ sort: LibrarySort) -> String {
        switch sort {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        case .title: "Title"
        case .longestFirst: "Longest first"
        }
    }
}

private struct RecordingDetailsSheet: View {
    let session: RecordingSession
    let managedBytes: Int64?
    let sourceBytes: Int64?
    let save: (String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var tags: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(session: RecordingSession, managedBytes: Int64?, sourceBytes: Int64?, save: @escaping (String, String) async throws -> Void) {
        self.session = session
        self.managedBytes = managedBytes
        self.sourceBytes = sourceBytes
        self.save = save
        _title = State(initialValue: session.title)
        _tags = State(initialValue: session.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording details").font(.title2.weight(.semibold))
            if let managedBytes {
                Text("Total storage: \(ByteCountFormatter.string(fromByteCount: managedBytes, countStyle: .file))\nRetained source audio: \(ByteCountFormatter.string(fromByteCount: sourceBytes ?? 0, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Recording name")
            VStack(alignment: .leading, spacing: 5) {
                TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Recording tags")
                Text("Up to 10 tags, 24 characters each.").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save") {
                    guard !isSaving else { return }
                    isSaving = true; errorMessage = nil
                    Task {
                        do { try await save(title, tags); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                        isSaving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 430)
        .interactiveDismissDisabled(isSaving)
    }
}

private struct DeleteRecordingSheet: View {
    let session: RecordingSession
    let managedBytes: Int64?
    let moveToTrash: () async throws -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isMoving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move “\(session.title)” to Trash?").font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text("This moves this recording, its source audio, and its internal exports to Trash. Separate clips and copies saved outside the app stay where they are.")
                .fixedSize(horizontal: false, vertical: true)
            if let managedBytes {
                Text("Managed storage: \(ByteCountFormatter.string(fromByteCount: managedBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel(); dismiss() }.keyboardShortcut(.defaultAction).disabled(isMoving)
                Button("Move to Trash", role: .destructive) {
                    guard !isMoving else { return }
                    isMoving = true; errorMessage = nil
                    Task {
                        do { try await moveToTrash(); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                        isMoving = false
                    }
                }.disabled(isMoving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(isMoving)
        .onExitCommand { if !isMoving { onCancel(); dismiss() } }
    }
}

private struct LevelMeter: View {
    let title: String
    let level: Float
    private var fraction: Double { level > 0 ? min(1, max(0, (20 * log10(Double(level)) + 60) / 60)) : 0 }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.caption).frame(width: 88, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(level >= 1 ? Color.orange : Color.accentColor)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }.frame(height: 6).accessibilityHidden(true)
            Text(level >= 1 ? "High" : level > 0.001 ? "Active" : "Quiet")
                .font(.caption2).foregroundStyle(level >= 1 ? .orange : .secondary).frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(level >= 1 ? "High input level" : level > 0.001 ? "Audio detected" : "Quiet")
    }
}
