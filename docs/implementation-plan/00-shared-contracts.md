# Shared contracts, state, and migration

Read this before implementing any feature. All later tasks depend on these choices. Do not build a second recording engine or second independent library.

## Baseline before implementation

These bullets describe the original implementation, not the current checkout. See [architecture](../architecture.md), [review fixes](../review-fixes.md), and [validation](../validation.md) for current behavior. The general render/derived-job contracts below remain requirements for later milestones; primary AAC commits currently use a per-session `pending-export.json` journal.

- `RecordingSession` uses schema version 1. Codable is synthesized; adding a nonoptional property with an initializer default does **not** provide a missing-key decoding default.
- All exported sessions currently assume `Recording.m4a`, stereo, 48 kHz. `exportURL`, player, Save Copy, row labels, allowed content types, writer, and validator share that assumption.
- `completeExport` removes raw segments after a fully successful export. Old completed sessions commonly have only M4A audio.
- Session writes are atomic and synchronized, but saving an old whole-session value can overwrite newer metadata. A serial lock alone does not fix stale snapshots.
- Capture duration currently comes from the transport's accepted frames; the time limit uses system uptime. Both need deliberate changes for pause/resume.
- `recorder_transport_stop` is terminal. The ring has no resume operation. Never clear its fault/accepting flags as a shortcut.
- `RecorderModel` directly owns playback and file-copy operations. `selectedID` can become stale after filtering/deletion unless explicitly reconciled.

## Schema version 2

Implement explicit versioned decoding/encoding and validation. Add small types in `RecorderCore` rather than arbitrary dictionaries. The exact Swift naming can follow existing conventions, but the following information is required:

| Type/field | Contract |
|---|---|
| Session `schemaVersion` | Encode 2 after migration. Read 1 and 2. Reject unsupported future versions without rewriting/deleting their files. |
| Existing identity/capture data | Preserve UUID, creation date, sample rate, microphone channels, segments, capture completion, and issue. |
| `title` | Existing field becomes visible/editable. See library spec for normalization. |
| `tags`, `isFavorite` | Defaults `[]`, `false` for v1. |
| `kind` | `capture`, `clip`, or `cleanedCopy`; default `capture` for v1. |
| `sourceRetention` | Explicitly `retained`, `notRetained`, or `notApplicable`. New captures use retained. Derived clips/cleaned copies use notApplicable. |
| `assets` | Array of validated internal exported-file records. Initially one primary; extra format exports can append more. |
| `primaryAssetID` | Optional until a validated primary exists. Refer only to an entry in assets. |
| Asset data | UUID, safe relative path, container/codec, sample rate, channel count, decoded frame count/duration, measured peak, byte size, creation date, render settings/source quality provenance. |
| Asset `validationState` | `verified` for newly committed output; `legacyNeedsValidation` for a migrated old asset until its file is actually inspected/decoded. Measured fields may be absent only in the latter state. |
| Optional derivation | Parent session/asset ID for information only; source range and cleanup settings. No filesystem dependency on the parent after creation. |
| `captureExportSettings` | Optional for v1; snapshot the default output preset when a new capture starts so a later preference edit cannot change it mid-session. |

Use computed primary-asset duration/peak instead of two independently mutable copies. Decode v1 `exportedDuration`/`exportedPeak` into a legacy primary asset when status is ready/partial. Preserve an explicit legacy/unverified-metadata marker if old optional properties are absent; validate the actual file before further audio work. Do not invent a successful codec validation during metadata migration.

Migration rules:

1. Decode and validate v1 before converting it. v1 ready/partial maps to a legacy `Recording.m4a` primary asset with AAC codec. Use the session UUID as that legacy asset's ID so repeated decode/migration attempts produce the same identity. Keep the file where it is; do not move audio during migration.
2. v1 ready -> sourceRetention notRetained (the old cleanup contract). v1 recorded/interrupted/recording/preparing and partial -> retained. Missing retained files are an error or explicit partial recovery, not evidence that cleanup succeeded.
3. Unknown/new schema, wrong UUID, traversal paths, malformed files: report unreadable and preserve the folder.
4. Save a byte-for-byte `session-v1.backup.json` once, without overwriting a pre-existing backup, before first persistent conversion. Atomically write/synchronize v2. Failure must leave v1 recoverable. Decode-only listing need not eagerly rewrite every session.
5. On startup, crashed capture-kind recording/preparing/pausing/paused/resuming sessions become interrupted; never automatically start capture. Paused sessions are recoverable, not automatically successful recordings. Derived jobs use the separate pending-render lifecycle below, not raw-capture recovery.
6. Clips/cleaned copies have no capture segments and are valid when their completed primary asset exists. They inherit the source integrity/partial outcome, not an invented claim of new live capture. Do not fake raw segment metadata to satisfy old guards.

Update `duration`, `canExport`, primary-asset resolution, startup recovery, and validation accordingly. Check all status switches. Distinguish raw recovery/export from re-exporting a saved asset.

## Paths and source retention

- Preserve UUID session directory names. A displayed title must never become the internal folder path.
- Preserve legacy `Recording.m4a`; new assets use generated paths such as `exports/<asset-UUID>.<correct-extension>`.
- Validate relative paths as components: no absolute paths, empty traversal components, `.`/`..`, escaped separators, or arbitrary parent directories. Reject symlink redirects in managed session/asset paths. Match extension to allowed container; an extension alone is not format validation.
- New captures keep raw system/microphone CAF files after export. Change `completeExport` so it follows retention policy rather than unconditionally deleting complete sources.
- Explain retained-source disk usage in settings/library details. At 48 kHz stereo plus mono microphone, Float32 source data is about 2.07 GB/hour before exports. Existing disk-headroom checks remain mandatory; users reclaim storage by deleting sessions through Trash.
- Do not change old sessions' notRetained status to retained because a stray raw file exists. No silent fallback from damaged supposedly-retained sources to a lossy asset.
- Prefer verified retained source segments when rendering a capture. For legacy sessions without retained sources, use the selected saved asset and mark that lossy provenance. A WAV made from AAC does not restore original quality.
- External copies are independent user files. Never include them in session deletion or use them as the only recovery copy.

## Operation ownership and UI rules

Use one owner for commands and a clear file-operation state. Extend capture phase with pausing/paused/resuming; keep playback state separate. A `FileOperationState` may describe choosing a folder, awaiting confirmation, metadata save, Trash, render, or copy. Do not scatter unrelated booleans across row views.

For this implementation, serialize mutating file operations globally. Disable recording start and competing mutations while one is running. Disable rename/delete/render/copy/playback during an active capture, including paused and transition states. Search and sorting can remain usable. Before rendering, copying, or deleting, stop playback and previews. This conservative policy avoids audio/file races; do not add a complex concurrent job scheduler.

- Guard commands synchronously before launching a Task, and repeat relevant identity/existence checks after dialogs return.
- Every async operation carries a UUID/generation. Late progress, player callbacks, library scans, and previews cannot update a newer selection/job.
- At mutation commit, reload the latest session under the store's serialization mechanism and update only the permitted fields. Do not save a stale capture/render snapshot over renamed/tagged data.
- Filesystem scans, hashing, copying, codec work, and Trash calls run off MainActor. AppKit panels, player/control state, and UI updates stay on MainActor. No audio buffer arrays cross to UI updates.
- Keep the existing serial CaptureService queue as sole owner of capture graph/writers. Do not evade Swift 6 errors by broadly marking mutable classes unchecked Sendable or changing the package to Swift 5.
- Preserve the preallocated C real-time callback. No locks, allocation, filesystem I/O, format encoding, cleanup DSP, logging, or UI work belongs there.
- An error in playback/export must be shown in that operation's context; it must not manufacture a successful capture or wipe a useful result.

Suggested focused components: `LibraryModel`, `PlaybackController`, `RenderRequest`/`RenderService`, `ExportDestinationStore`/`ExportDeliveryService`. Reuse existing SessionStore and AudioExporter internals; rename/extract them incrementally. Do not invent repositories/databases for small in-memory filtering.

## Safe asset commit and recovery

Primary capture, extra format exports, clips, cleanup, and previews must share rendering/validation code. The service that commits a result must know which type of operation it is; a clip must never execute the parent's `completeExport` transition.

1. Snapshot request, source identities, settings, and the selected destination. Validate them before rendering.
2. Reserve the operation and write a small pending-job manifest under `Sessions/.jobs/<job-UUID>.json` with generated IDs, purpose, owning session, and expected target path. Validate these paths/IDs on read just like session paths. This allows startup to report completed-but-uncommitted work after a crash. New derived sessions use an explicit `pendingRender` status; allow their manifest to exist without an asset only while pending, and keep them out of the normal playable list until committed. Surface unfinished derived jobs in a recovery/error section. Do not treat them as raw captures with missing segments.
3. Render to a generated temporary file on the same volume as its internal target. Preserve source files throughout.
4. Close/check/synchronize output, decode it completely, validate expected codec/container/channels/rate/duration/finite samples/peak, and check cancellation before commit.
5. Rename to a unique internal asset path without overwriting another asset. Commit fresh session metadata atomically. Clear the pending manifest only after metadata success.
6. On metadata failure after file promotion, keep the validated output and pending manifest for recovery. Do not blindly delete a file another successful step now owns. Report partial job completion accurately.
7. On startup, inspect pending jobs: do not trust an orphan just because it has an audio extension. Validate before offering recovery/committing. Preserve uncertain files and show the issue. Never present a partially encoded clip as ready.
8. A selected external destination is a subsequent copy/delivery step. External failure must not roll back internal success.

Cancellation is accepted until the internal commit starts. The short atomic commit is non-cancellable. If cancellation arrives after commit, report the saved internal result; do not call it cancelled/lost. No raw cleanup is allowed by cancellation or derived-asset creation.

## Common source and frame contracts

`RenderRequest` must explicitly identify a source (retained session segments or a saved asset), optional source-frame range `[start, end)`, format/preset, optional cleanup settings, and purpose (primary export/additional export/new clip/new cleaned copy/temporary preview). It must not contain a mutable view model.

- Frame ranges are Int64, checked for overflow, at the source sample rate. UI seconds are presentation only. Use one documented seconds-to-frame conversion throughout (floor start, ceil end, clamp to actual source length).
- Output duration derives from selected source frames divided by source rate, never the UI stopwatch or playback rate.
- Memory use scales with a bounded processing block, not recording length. Writer/client/channel formats must be explicit and tested.
- A processing chain is deterministic across block/segment boundaries. Do not reset resamplers, denoisers, or filters every 30-second segment.
- A failed complete source is not EOF or silence. Best-effort partial recovery remains explicit, with preserved source files and issue labels.

## Required baseline checks

Run existing scripts before changing code and retain their results. Prior validation reported 21 Swift checks plus the concurrent C test; verify current results rather than repeating the historical number as new evidence.

```sh
zsh Scripts/check.sh
zsh Scripts/check-transport.sh
zsh Scripts/build-app.sh
```

Codec/GUI checks require normal macOS service access; sandbox-restricted failures must be labeled and rerun with the environment's approved permission mechanism. Never bypass low-space checks or fake codec success to make tests green. See [integrated verification](09-verification.md).
