# Architecture and extension points

```text
RecorderApp   AppKit window/menu/quit lifecycle
    |
RecorderUI    SwiftUI views + main-actor RecorderModel
    |
    +-- Capturing protocol -> CaptureService serial control/writer queue
    |                            |
    |                        CaptureGraph -> Core Audio tap + aggregate
    |                            |
    |                        AudioTransport C callback + bounded SPSC buffer
    |                            |
    |                        synchronous background CAF segment writer
    |
    +-- AudioExporting protocol -> background scan / encode / validate
    |
RecorderCore  Session schema, state labels, input/storage policy, SessionStore
```

## Capture

The C callback copies supported Float32 buffers into a preallocated single-producer/single-consumer ring. The ring stores system L/R followed by the selected microphone channels, without downmixing. It latches overflow, layout changes, invalid samples, and sample-timestamp discontinuities; it stops accepting audio after a fault. It never silently resumes after dropped audio.

The control queue drains that buffer into explicitly closed CAF segments, up to 30 seconds each. Session metadata is written before opening a segment and after finalization. File write/close failures affect the session outcome. Core Audio properties and free space are checked periodically, and callback delivery has a watchdog independent of amplitude: silence is valid audio.

The graph supports a deliberately constrained layout: a single stereo tap, optionally preceded by one mono/stereo microphone stream. Other layouts fail explicitly. The aggregate nominal rate is the capture clock. The tap's native format rate can differ when a Bluetooth microphone is the aggregate clock, so callback frame counts and runtime format changes are checked as well. Hardware qualification remains necessary.

CaptureGraph is owned exclusively by CaptureService's serial queue. Callback state is C-owned. A failed callback detachment prevents freeing its context or starting another session until cleanup succeeds; the process may retain a bounded buffer until exit rather than risk use-after-free.

Pause cancels watchdog timers, detaches/drains/closes the graph and writers, and persists the accepted frame count. Resume recreates the graph with the original microphone UID and verifies the format before accepting more frames. Segment creation is lazy, preventing empty tails at pause boundaries. Limits and elapsed time use written capture frames, never wall-clock paused time. The model queues Stop during pause/resume transitions; failed teardown blocks unsafe graph reuse.

## Session storage

SessionStore serializes filesystem access. Metadata uses schema version 2, generated UUID/segment paths, explicit saved-audio assets, and source-retention state. Older version-1 manifests decode without modification and receive a byte-exact backup before their first rewrite. Writes are atomic and synchronized. On launch, recording/preparing/paused/transition sessions become interrupted; exporting sessions become retryable. Unreadable folders are kept and counted, never pruned.

Metadata commands reload the latest manifest under the store lock and patch only the fields being edited. Favorite toggles therefore cannot undo a rename or reject an unchanged legacy name. Verified assets require measured frame count, duration, peak, and file size; legacy duration conversion is checked before any integer conversion. Asset resolution rejects symlinks in every managed path component.

Interrupted sessions can produce explicitly partial M4As from surviving sources, keeping original data for further recovery. New captures retain their source segments after successful exports. Deletion validates a direct UUID child with matching metadata and moves that whole managed folder through an injectable Trash service; it never falls back to permanent deletion.

## Rendering, cleanup, and delivery

`AudioExporting` remains the capture/model adapter; its implementation delegates to the same `AudioRenderService` used by format exports, clips, cleaned copies, and previews. Immutable `RenderRequest` values snapshot source, frame range, preset, purpose, title, and processing choices. `AudioSourceReader` validates retained raw segments or explicitly legacy/derived saved assets, preserves source timing and partial gaps, and visits bounded blocks. Damaged retained sources never silently fall back to compressed audio.

The render worker uses checked ExtAudioFile conversion to a 48 kHz multichannel Float32 CAF. One checked processed stereo CAF makes the analysis and encode passes deterministic. Memory and open source handles are bounded; disk estimates include both intermediates, two output estimates, and reserve space. Frame selections use floor(start)/ceil(end) at the source sample rate; saved clips begin at zero.

`AudioProcessor` owns per-job/per-channel state. Its optional chain is an 80 Hz first-order high-pass, pinned RNNoise, source mixing, and bounded whole-mix RMS gain. RNNoise uses 16-bit amplitude scaling on Float32 data, independent channel states, 480-sample frames, initial-latency removal, and a flushed final frame. Microphone-only processing keeps the system track aligned and untouched before normal mixing/headroom. Preview includes up to one second of pre-roll and excludes it from playback. All effects default off.

`ExportPreset` declares three AAC bitrates and 24-bit WAV/ALAC/FLAC. Native codec IDs are queried and each preset is write/decode probed once per launch. `AudioValidation` checks actual codec/container, decoded frame count, sample rate/channels, finite samples, peak, and lossless bit depth. Overshoot permits one lower-gain retry. Original lossy provenance and processing settings are recorded on the new asset. Additional exports preserve the existing primary asset. Clips/cleaned copies own independent sessions and inherit any partial-source issue.

`render-job.json` persists intent before processing. Interrupted jobs reuse their owner, range, preset, and processing options through Finish saving. Generated working paths are recorded, validated, and cleaned on retry. `pending-export.json` persists validated asset identity before promotion. Recovery revalidates the audio, appends the same asset at most once, then clears render intent before clearing the asset journal. This ordering prevents duplicate exports after metadata succeeds but cleanup is interrupted. Cancellation removes only uncommitted job artifacts; capture sources and committed assets remain. Previews use separately guarded disposable directories. A process crash can still leave a preview directory for later manual cleanup; automatic age-based pruning is not implemented.

`ExportDestinationStore` saves preferences separately from session metadata and resolves folder bookmarks. For this direct-distribution, nonsandboxed app, a minimal bookmark tracks the chosen folder; an App Store sandbox would need its own entitlement/security-scoped bookmark qualification. Managed storage and descendants cannot be destinations. Filename tokens use creation time and a sanitized, byte-bounded basename.

`ExportDeliveryService` copies only an already committed asset. A synchronized journal records the target, generated name, size, SHA-256, and state. Copies use bounded streaming, a synchronized temporary file, and atomic no-replace promotion. Collisions receive suffixes; a retry can adopt an already-published file only when size/hash match. A failed copy never changes internal recording success. Delivery notices are refreshed with library snapshots. External copies are independent of Trash operations.

## UI and lifecycle

RecorderModel is main-actor isolated, with phases for idle, preparing, recording, pausing, paused, resuming, stopping, exporting, and failed. Controls and headings derive from phase. Device options cannot change mid-recording. Operation identifiers reject stale capture events. A separate main-actor PlaybackController owns the sole AVAudioPlayer, progress timer, seek state, and speed/volume preferences. The root content scrolls, with bounded minimum window dimensions and wrapping diagnostic text.

`RecordingLibrary` caches filtered results and invalidates in-flight scans before mutations. Activation refreshes detect restored or missing files; filtering alone never stops playback. Startup recovery finishes before commands are enabled. Scans are deferred while capturing or exporting to avoid competing with the writer's store lock. Metadata saves, copy panels, and Trash reservations block competing commands synchronously.

`PlaybackPlayer` separates native audio operations from playback state. Production uses AVAudioPlayer; deterministic checks inject a controllable player. Each play run has a delegate relay with a generation token, so late finish/decode callbacks cannot modify a newer run. Natural completion comes from the delegate, since the native player may reset its time at EOF. `PlaybackWindow` handles Space through the window responder chain, leaving text input and sheets alone.

The AppKit shell intercepts window close before hiding the window. Cancelling quit leaves controls visible. Normal quit awaits stopping/saving, metadata, Trash, copy, and initial recovery work, and cancels an unsubmitted copy panel. Failed exports keep their recoverable sources. Playback stops before recording, copying, and confirmed deletion. Finder/copy/playback errors stay separate from capture phase, so they cannot disable Stop during a live recording.

## Adding features

- New input sources belong behind Capturing and explicit channel/layout metadata.
- New export formats belong behind AudioExporting and must keep the same validation/commit contract.
- Transcription should eventually consume a separate bounded stream and remain independent of capture success. It is not included now.
- Schema changes require a versioned migration with recovery tests.
- App Store sandboxing requires a separate storage/bookmark and entitlement design; choosing a signing certificate must not toggle it.

`RecordingWorkflow` owns one cancellable render/delivery operation, immutable settings snapshots, and one preview using the existing playback controller. Editors reserve conflicting capture/library actions, and shutdown awaits/cancels outstanding work and folder panels.

RNNoise is a separate vendored C target; revision, model hash, local patches, reproducible build inputs, and licenses are in `Vendor/RNNoise/README.md`. The app contains the compiled model and third-party notices and performs no downloads. Regression checks use generated audio, real service implementations, and small injectable graph/writer/player/Trash boundaries; test-only code is not bundled.
