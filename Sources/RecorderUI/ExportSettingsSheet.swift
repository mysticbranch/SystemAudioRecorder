import SwiftUI
import RecorderCore

struct ExportSettingsSheet: View {
    @ObservedObject var workflow: RecordingWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DestinationSettings
    @State private var error: String?
    @State private var choosing = false
    private let sample = RecordingSession(title: "Meeting notes")
    init(workflow: RecordingWorkflow) { self.workflow = workflow; _draft = State(initialValue: workflow.settings) }
    private var preview: String? { try? FilenamePattern.expand(draft.pattern, session: sample) + "." + draft.defaultPreset.fileExtension }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export settings").font(.title2.weight(.semibold))
            ExportPresetPicker(selection: $draft.defaultPreset, workflow: workflow)
            Text("The default format is fixed when recording starts. All formats use 48 kHz stereo.").font(.caption).foregroundStyle(.secondary)
            Toggle("Save exported copies automatically", isOn: $draft.automaticallyCopy)
            HStack {
                Text(draft.displayPath).font(.caption).textSelection(.enabled).lineLimit(3)
                Spacer()
                Button("Choose folder…") {
                    choosing = true
                    Task {
                        defer { choosing = false }
                        do { if let result = try await workflow.chooseFolder() { draft.bookmark = result.0; draft.displayPath = result.1 } }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(choosing || workflow.isBusy)
            }
            Text("The app keeps its internal recording for recovery. The selected folder receives a copy; cloud or external-drive software controls any further syncing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Filename pattern").font(.caption)
            TextField("Filename pattern", text: $draft.pattern).textFieldStyle(.roundedBorder).accessibilityLabel("Filename pattern")
            Text("Tokens: {date}, {time}, {title}, {id}. The format supplies the extension.").font(.caption).foregroundStyle(.secondary)
            Text(preview.map { "Example: " + $0 } ?? "The filename pattern is invalid.").font(.caption).textSelection(.enabled)
            ForEach(workflow.capabilities.filter { !$0.isAvailable }, id: \.preset) { capability in
                Text("\(capability.preset.title): \(capability.unavailableReason ?? "Unavailable")").font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Reset to defaults") { draft = DestinationSettings() }.disabled(workflow.isBusy || choosing)
                Spacer()
                Button("Cancel") { workflow.closeEditor(); dismiss() }.keyboardShortcut(.cancelAction).disabled(workflow.isBusy || choosing)
                Button("Save") {
                    Task {
                        do { try await workflow.saveSettings(draft); workflow.closeEditor(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(workflow.isBusy || choosing || preview == nil)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(workflow.isBusy || choosing)
    }
}
