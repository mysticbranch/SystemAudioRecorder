# Recording workflow implementation handoff

Prepared 2026-09-09 from the current source checkout. **Status: all eight requested capabilities are implemented locally**, including the shared renderer, durable render/delivery jobs, format provenance, and pinned RNNoise. See [implementation progress](../implementation-progress.md), [review fixes](../review-fixes.md), and [current validation](../validation.md). Automated implementation evidence does not complete listening, hardware, accessibility, or public-release qualification.

## Objective and scope

Implement the eight requested capabilities while preserving recording integrity, recovery, and a responsive native macOS interface:

1. Pause/resume recording (original idea 2).
2. Playback controls (idea 3).
3. Rename, search, tags, favorites, and sorting (idea 4).
4. Non-destructive trim and clip creation (idea 5).
5. Preferred export folder and filename pattern (idea 8).
6. Export formats and quality presets (idea 9).
7. Optional offline audio cleanup (idea 19).
8. Delete a recording by moving its managed session folder to Trash.

This is a change to existing functionality, new features, and supporting refactoring. Do not add transcription, app-specific capture, scheduling, cloud sync, a replay buffer, or a full audio editor. No network access is needed by the running app. Audio cleanup's optional user-controlled speech-denoising mode is included; it is not permission to download models during recording.

## Read first

- Parent workspace `AGENTS.md` and `GITHUB-ADHOC.md`: this is a personal project. Do not use work-account Git credentials or change global configuration. Do not publish unless the active user request authorizes it.
- [Current architecture](../architecture.md), [validation record](../validation.md), [release checklist](../release-checklist.md).
- [Shared contracts and migration](00-shared-contracts.md). These are requirements for every task.

Source paths below are relative to the repository root. The project is a Swift 6 package with a macOS 14.2 deployment target, C audio transport, SwiftUI content, and an AppKit application shell. There is no third-party runtime dependency at baseline. Keep that baseline for all tasks except the explicitly isolated RNNoise integration.

The source files were untracked when this document was prepared. Preserve them; do not use `git clean`, reset the checkout, recreate the project, or assume HEAD contains a recoverable baseline. Inspect status again before editing. Follow the parent's identity rules if commits are requested.

## Implementation order

This order addresses dependencies rather than product priority. Complete and check one milestone before the next; each intermediate build should work.

| Order | Specification | Depends on | Completion evidence |
|---|---|---|---|
| 0 | [Shared contracts](00-shared-contracts.md) | Existing app | Schema migration, source retention, safe asset paths, operation guards |
| 1 | [Library organization](01-library.md) | 0 | Rename/filter/tag/favorite tests and UI review |
| 2 | [Delete recording](02-delete.md) | 0–1 | Trash failure/success/cancellation tests |
| 3 | [Playback controls](03-playback.md) | 0–1 | Real player seek/rate/pause tests and synchronized controls |
| 4 | [Recording pause/resume](04-pause-resume.md) | 0 | Real CaptureService lifecycle tests, frame continuity, manual hardware check |
| 5 | [Formats and render pipeline](05-formats.md) | 0, 3 | All supported formats decoded and validated; old recordings still work |
| 6 | [Destination and naming](06-destination.md) | 5 | Bookmark, collision, failed-copy, and retry tests |
| 7 | [Trim and clips](07-trim.md) | 1–3, 5–6 | Exact range, immutable original, independent clip recovery |
| 8 | [Audio cleanup](08-cleanup.md) | 3, 5–7 | Processing bypass, alignment, level limits, denoise tests/listening |
| 9 | [Integrated acceptance](09-verification.md) | All | Full regression suite, UI checks, honest remaining-device matrix |

Do not implement multiple unrelated milestones in one large edit. Add meaningful regressions with each milestone. Do not silently remove a requirement because it is difficult: record the precise blocker and leave that capability explicitly incomplete.

## Product decisions already made for this implementation

- Pause really stops this app's capture graph. Resuming continues the same session with a new source segment. Paused wall time is omitted.
- The automatic-stop setting measures captured audio time, not time spent paused.
- Capture settings cannot be changed during a paused session. Resume requires the same compatible source configuration.
- Playback, trimming, export, and cleanup use an explicitly selected recording/asset, never the first search result or a stale row index.
- Retain raw source segments for **new recordings**, including after successful export. This enables later clean exports and editing. Display the storage cost and include those sources in Trash deletion. Do not manufacture raw sources for old recordings.
- The library keeps an internal recording even when an automatic external copy fails. A preferred folder is an export destination, not the recovery-store location.
- Trimming and cleanup create independent new recordings. They do not overwrite an original or depend on its continued existence.
- Formats: AAC/M4A presets, WAV PCM, ALAC/M4A, FLAC when supported. MP3 is explicitly outside this implementation.
- Cleanup is offline, default off, with explicit preview and Save cleaned copy. Never process the real-time audio callback.
- Delete means **Move to Trash**, including the session's internal assets and sources. Never delete external copies and never silently fall back to permanent deletion.
- Keep the current minimum macOS version. Availability checks, codec capability checks, and errors must match it.

These choices reduce ambiguity for implementation; they are not evidence of user testing. If a technical incompatibility requires changing a contract, describe the evidence and update all affected specs/tests together.

## Suggested prompt for the implementing model

> Continue the requested recording-workflow features in `docs/implementation-plan/README.md`. Read its current status, `00-shared-contracts.md`, and `docs/validation.md` first. Follow the numbered specifications in dependency order within the scope the user authorizes. Inspect actual files before each milestone; preserve the app and untracked work. Work through one milestone at a time, implement it, run relevant checks, and review the diff. Do not replace tested behavior with mocks, disable concurrency checks, add unrelated features, or claim unrun tests passed. Preserve user audio and schema compatibility. Keep a progress record listing implemented, verified, and still unverified behavior. See `09-verification.md` for completion criteria.

## Baseline file map

| Area | Current files and entry points |
|---|---|
| Metadata/storage | `Sources/RecorderCore/RecordingSession.swift`; `SessionStore.swift` (`load`, `save`, `list`, `completeExport`, `exportURL`); `RecordingCopy.swift` |
| Capture | `Sources/RecorderAudio/CaptureService.swift` (`Capturing`, `tick`, `drain`, `openSegment`, `closeSegment`, `finish`) |
| Device lifecycle | `Sources/RecorderAudio/CaptureGraph.swift` (`start`, `detach`, `close`); `AudioDevices.swift` |
| Real-time transport | `Sources/AudioTransport/AudioTransport.c`, `include/AudioTransport.h` |
| Audio output | `Sources/RecorderAudio/AudioFileWriter.swift`; `AudioExporter.swift` (`plan`, `visit`, `perform`, `validateExport`) |
| Application model | `Sources/RecorderUI/RecorderModel.swift` (`start`, `stop`, `recover`, `save`, `togglePlayback`, `saveCopy`, `shutdown`) |
| Interface | `Sources/RecorderUI/ContentView.swift` (`recordingCard`, `recordings`, `sessionRow`) |
| Window/quit | `Sources/RecorderApp/SystemAudioRecorderApp.swift` (`windowShouldClose`, `applicationShouldTerminate`) |
| Regression runner | `Tests/RecorderChecks/RecorderChecks.swift`; `Tests/AudioTransportChecks.c` |
| Build/checks | `Package.swift`, `Scripts/check.sh`, `Scripts/check-transport.sh`, `Scripts/build-app.sh`, `.github/workflows/check.yml` |

New files suggested in the individual specs are additions, not files already present. Keep business logic out of SwiftUI view bodies. Extract focused controllers/services instead of continuing to grow `RecorderModel` indefinitely.
