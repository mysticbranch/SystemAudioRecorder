import SwiftUI
import RecorderCore

struct RenderEditorSheet: View {
    let session: RecordingSession
    let purpose: RenderPurpose
    @ObservedObject var workflow: RecordingWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var sourceRange: AudioFrameRange?
    @State private var start = "0"
    @State private var end = ""
    @State private var previewStart = "0"
    @State private var title: String
    @State private var preset: ExportPreset
    @State private var processing: AudioProcessingOptions
    @State private var processedPreview = true
    @State private var copyToFolder: Bool
    @State private var error: String?

    init(session: RecordingSession, purpose: RenderPurpose, workflow: RecordingWorkflow) {
        self.session = session; self.purpose = purpose; self.workflow = workflow
        _title = State(initialValue: String(session.title.prefix(100)) + (purpose == .clip ? " — Clip" : " — Cleaned"))
        _preset = State(initialValue: workflow.settings.defaultPreset)
        _copyToFolder = State(initialValue: workflow.settings.automaticallyCopy)
        _processing = State(initialValue: AudioProcessingOptions(target: session.kind == .capture && session.sourceRetention == .retained && session.microphoneChannels > 0 ? .microphoneOnly : .entireRecording))
    }
    private var heading: String { purpose == .clip ? "Trim and save a clip" : purpose == .cleanedCopy ? "Clean up audio" : "Export recording" }
    private var action: String { purpose == .clip ? "Save clip" : purpose == .cleanedCopy ? "Save cleaned copy" : "Export" }
    private var separateMicrophone: Bool { session.kind == .capture && session.sourceRetention == .retained && session.microphoneChannels > 0 }
    private var sourceIsLossy: Bool { !(session.kind == .capture && session.sourceRetention == .retained) && (session.primaryAsset?.codec == .aac || session.primaryAsset?.provenance?.sourceWasLossy == true) }
    private func range(preview: Bool = false) throws -> AudioFrameRange {
        guard let sourceRange else { throw RecorderFailure("Reading the source audio…") }
        if purpose == .clip {
            return try AudioFrameRange(startSeconds: AudioTimeInput.seconds(start), endSeconds: AudioTimeInput.seconds(end), sampleRate: sourceRange.sampleRate, totalFrames: sourceRange.end)
        }
        if preview {
            let first = try AudioTimeInput.seconds(previewStart)
            return try AudioFrameRange(startSeconds: first, endSeconds: min(sourceRange.duration, first + 15), sampleRate: sourceRange.sampleRate, totalFrames: sourceRange.end, minimumDuration: 0)
        }
        return sourceRange
    }
    private var validationError: String? {
        do {
            _ = try range()
            if purpose != .additional { _ = try LibraryRules.normalizedTitle(title) }
            guard workflow.isSupported(preset) else { throw RecorderFailure("Choose an available output format.") }
            if copyToFolder && workflow.settings.bookmark == nil { throw RecorderFailure("Choose an export folder in Export settings, or turn off the copy option.") }
            return nil
        } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading).font(.title2.weight(.semibold))
            Text(session.title).font(.callout).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if sourceIsLossy {
                        Text("This uses previously compressed audio. A lossless output format cannot restore detail lost earlier.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if purpose != .additional {
                        TextField("New recording name", text: $title).textFieldStyle(.roundedBorder).accessibilityLabel("New recording name")
                    }
                    if purpose == .clip { trimControls }
                    if purpose == .cleanedCopy { cleanupControls }
                    ExportPresetPicker(selection: $preset, workflow: workflow)
                    Toggle("Also copy to the selected export folder", isOn: $copyToFolder)
                    if copyToFolder { Text(workflow.settings.displayPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if purpose != .additional {
                        HStack {
                            Button("Preview selection") { run(preview: true) }.disabled(workflow.isBusy || validationError != nil)
                            Button("Stop preview") { workflow.invalidatePreview() }.disabled(workflow.isBusy)
                        }
                        Text(purpose == .clip ? "Preview plays only the selected range." : "Preview plays up to 15 seconds from the preview start. Saving processes the full recording. Stateful processing uses up to one second of pre-roll.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Original audio stays unchanged. New files are stored independently inside the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 4).disabled(workflow.isBusy)
            }.frame(maxHeight: 430)
            if workflow.isBusy { ProgressView(value: workflow.progress); Text("Processing and validating audio…").font(.caption) }
            if let message = error ?? validationError {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if workflow.isBusy { Button("Cancel processing") { workflow.cancel() } }
                Spacer()
                Button("Close") { workflow.closeEditor(); dismiss() }.keyboardShortcut(.cancelAction).disabled(workflow.isBusy)
                Button(action) { run(preview: false) }.keyboardShortcut(.defaultAction)
                    .disabled(workflow.isBusy || validationError != nil)
            }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(workflow.isBusy)
        .task {
            do {
                let value = try await workflow.renderer.sourceRange(sessionID: session.id)
                sourceRange = value; end = String(value.duration)
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: start) { _, _ in workflow.invalidatePreview() }
        .onChange(of: end) { _, _ in workflow.invalidatePreview() }
        .onChange(of: previewStart) { _, _ in workflow.invalidatePreview() }
        .onChange(of: processing) { _, _ in workflow.invalidatePreview() }
        .onChange(of: processedPreview) { _, _ in workflow.invalidatePreview() }
        .onChange(of: preset) { _, _ in workflow.invalidatePreview() }
    }
    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start").font(.caption)
                    TextField("Start", text: $start).accessibilityLabel("Clip start time")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("End").font(.caption)
                    TextField("End", text: $end).accessibilityLabel("Clip end time")
                }
            }.textFieldStyle(.roundedBorder)
            Text("Seconds, mm:ss, or hh:mm:ss; decimal seconds are supported. Minimum clip: 0.25 seconds.").font(.caption).foregroundStyle(.secondary)
            if let sourceRange, sourceRange.duration > 0 {
                Slider(value: Binding(get: { min(sourceRange.duration, max(0, (try? AudioTimeInput.seconds(start)) ?? 0)) }, set: { start = String($0) }), in: 0...sourceRange.duration)
                    .accessibilityLabel("Clip start")
                Slider(value: Binding(get: { min(sourceRange.duration, max(0, (try? AudioTimeInput.seconds(end)) ?? sourceRange.duration)) }, set: { end = String($0) }), in: 0...sourceRange.duration)
                    .accessibilityLabel("Clip end")
            }
            if let selection = try? range() { Text("Clip duration: \(selection.duration, specifier: "%.3f") seconds").font(.caption.monospacedDigit()) }
        }
    }
    private var cleanupControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Apply cleanup to", selection: $processing.target) {
                Text("Entire recording").tag(AudioProcessingOptions.Target.entireRecording)
                if separateMicrophone { Text("Microphone only").tag(AudioProcessingOptions.Target.microphoneOnly) }
            }
            Toggle("Reduce rumble (80 Hz high-pass)", isOn: $processing.reduceRumble)
            Toggle("Reduce speech noise (RNNoise)", isOn: $processing.reduceSpeechNoise)
            Toggle("Normalize speech level (fixed gain)", isOn: $processing.normalizeSpeech)
            Text("Speech processing may alter music. Normalization targets the recording's active RMS level with gain and peak limits; it is not a compressor.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Preview start").font(.caption)
            TextField("Preview start", text: $previewStart).textFieldStyle(.roundedBorder).accessibilityLabel("Cleanup preview start time")
            Picker("Preview", selection: $processedPreview) {
                Text("Original").tag(false); Text("Processed").tag(true)
            }.pickerStyle(.segmented)
        }
    }
    private func run(preview: Bool) {
        guard !workflow.isBusy else { return }
        do {
            let selected = try range(preview: preview)
            let options = purpose == .cleanedCopy && (!preview || processedPreview) ? processing : AudioProcessingOptions()
            let request = RenderRequest(sessionID: session.id, preset: preset, purpose: preview ? .preview : purpose,
                                        range: selected, processing: options, title: title)
            error = nil
            Task {
                do {
                    _ = try await workflow.perform(request, copyToFolder: !preview && copyToFolder)
                    if !preview { workflow.closeEditor(); dismiss() }
                } catch is CancellationError { self.error = "Processing cancelled. Original recordings are kept." }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct ExportPresetPicker: View {
    @Binding var selection: ExportPreset
    @ObservedObject var workflow: RecordingWorkflow
    var body: some View {
        Picker("Output format", selection: $selection) {
            ForEach(ExportPreset.allCases) { preset in
                Text(preset.title + (workflow.isSupported(preset) ? "" : " — unavailable")).tag(preset).disabled(!workflow.isSupported(preset))
            }
        }
    }
}
