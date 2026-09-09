import Foundation
import RecorderCore

public protocol AudioExporting: Sendable {
    func export(_ session: RecordingSession, progress: @escaping @Sendable (Double) -> Void) async throws -> RecordingSession
}

/// Capture export and recovery use the same checked renderer as clips and additional formats.
public final class AudioExporter: AudioExporting, Sendable {
    private let renderer: AudioRenderService
    public init(store: SessionStore) { renderer = AudioRenderService(store: store) }
    public func export(_ session: RecordingSession, progress: @escaping @Sendable (Double) -> Void) async throws -> RecordingSession {
        guard let preset = ExportPreset.fromStored(session.captureExportPresetID) else { throw RecorderFailure("The recording's saved export preset is unsupported.") }
        let result = try await renderer.render(RenderRequest(sessionID: session.id, preset: preset, purpose: .primary), progress: progress)
        guard let saved = result.session else { throw RecorderFailure("The recording was not committed.") }
        return saved
    }
}
