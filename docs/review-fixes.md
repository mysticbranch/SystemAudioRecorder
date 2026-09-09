# Corrective review of the first four implementation items

2026-09-09. Scope: shared storage foundations, library organization, Trash, and playback. Recording pause/resume is a later milestone. Classification: investigation, bug fixes, and supporting refactoring.

The earlier 28-check suite passed despite the following reproducible problems. These were corrected without changing the capture callback or deleting user recordings.

| Problem found | Correction | Components |
|---|---|---|
| A finite but oversized v1 duration crashed integer conversion during library loading. | Check range before conversion; isolate and preserve unsupported metadata. | `RecordingSession`, storage regressions |
| A symlink in the `exports` folder redirected asset resolution outside the session. Verified assets could omit measurements. | Check every managed asset-path component, codec/container pairing, and required measured fields. | `SessionStore`, `RecordingAsset` |
| Favorite updates could restore old names/tags, and names longer than the new limit could not be favorited. Details saves could reset a changed favorite. | Reload and patch only changed fields; toggle the latest favorite independently. | `SessionStore`, `RecorderModel` |
| Metadata failure after audio promotion left an untracked export. Error handling could overwrite newer metadata. | Synchronize a pending primary-export journal before promotion; preserve and revalidate pending audio; commit with fresh metadata. | `PendingExport`, `SessionStore`, `AudioExporter` |
| Finder failure changed a live recording to failed, disabling Stop while capture continued. | Separate file/UI errors from capture-operation failures. | `RecorderModel` |
| Startup recovery, metadata work, old scans, and competing commands could overlap. Quit did not await metadata/Trash work. | Block commands during recovery/mutations/scans; invalidate old scan results; await outstanding work on quit. Defer scans during capture/export. | `RecordingLibrary`, `RecorderModel` |
| Native playback completion was displayed as paused at zero; callbacks and panel actions lacked complete coordination. | Use per-run delegate tokens and a player adapter; fix completion/replay/seek-to-end/scrubbing; route controls through guarded commands. Add window-scoped Space handling. | `PlaybackController`, `PlaybackPlayer`, `PlaybackWindow`, app shell |
| Restored/deleted files and renamed player titles were not reconciled; tags were squeezed at minimum width. | Refresh on activation, release missing assets, update titles, keep tags horizontally scrollable, split row actions, show source/total bytes, protect saving/deleting sheets. | Library/model/SwiftUI |

Tests now include controlled metadata failures, delayed snapshots and player callbacks, genuine AVAudioPlayer completion, and a temporary-folder Trash implementation that actually moves and restores generated fixtures. They do not use the real macOS Trash. UI evidence includes 620-point light/dark layouts with long titles and ten long tags; visual inspection also caught and corrected a URL-comparison bug in the source-byte total.

The app remains a development preview. See [validation](validation.md) for commands/results and [release checks](release-checklist.md) for hardware, accessibility, real Trash, OS compatibility, signing, and distribution qualification. General render requests, clip/cleanup provenance, and derived-job lifecycle are still planned; the new journal covers existing primary AAC exports only.
