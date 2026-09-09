# Validation record

Date: 2026-09-09. Environment: macOS 26.6.2 (25G83), Apple Silicon, Swift 6.3.3 Command Line Tools. This is a development preview, not a qualified public release.

## Current workflow implementation

The later implementation in this same environment completed all eight requested capabilities locally. See [implementation progress](implementation-progress.md) for the feature-by-feature evidence and [RNNoise pin](../Vendor/RNNoise/README.md) for dependency/license details.

- `zsh Scripts/check.sh --ui-snapshots`: **62 passed, zero failed**, including 21 checks beyond the earlier 41-check review. Added real-service pause boundaries/cycles/failure handling, interrupted render intent, all six codec presets, frame-accurate independent clips, short-frame microphone-only denoising alignment, DSP level/response tests, collision-safe delivery/retry, settings, and preview cleanup.
- Both `Scripts/check-transport.sh` and `Scripts/check-rnnoise.sh` passed with AddressSanitizer and UndefinedBehaviorSanitizer. RNNoise source/model checksums passed.
- `Scripts/build-app.sh` built the updated arm64 release app and strict ad-hoc signature verification passed. Prior bundle retained under `.build/bundle.JMuWHV/previous.app`. Packaged third-party notices match the repository resource byte-for-byte.
- Inspected paused, trim, cleanup, and export-settings images. Snapshot backgrounds were corrected to emulate native sheets; persistent Start/End/Preview start/Filename pattern labels were added. Latest snapshots are in temporary evidence directory `recorder-checks-1A530E94-8C01-47E1-91A2-2C8C99E72F61`.
- Test data is generated and isolated. No live private audio or real Trash was exercised. The new bundle was not launched against the user's recording library. All physical-device, listening, accessibility, minimum-OS/Intel, long-duration, and release gates below remain open. Preview folders left by process crashes are not automatically pruned.

## Earlier corrective review

The following 41-check results record the preceding review, before the new workflow features:

- Debug compilation and `zsh Scripts/build-app.sh` passed after the corrective review. The updated arm64 app is in `dist/System Audio Recorder.app`; the build script retained the prior bundle under `.build/bundle.357LqL/previous.app`.
- Baseline before fixes: `zsh Scripts/check.sh` passed 28 checks despite independently reproduced state, migration, path, metadata, and playback bugs. See [review fixes](review-fixes.md).
- Final `zsh Scripts/check.sh --ui-snapshots`: **41 checks passed, zero failed.** Existing capture/export/transport coverage remains. Added checks cover oversized legacy numbers, future-schema preservation, intermediate symlinks, incomplete verified assets, metadata patch/write failures, stale library scans, 1,000-record filtering, failed export commit/recovery, actual playback completion/replay/scrubbing, controlled late callbacks/decode/play errors, Finder failure during capture, metadata operation guards and shutdown waiting, temporary-folder Trash cancellation/failure/restoration, renamed/missing playback assets, and window-scoped Space/text-editor behavior.
- Snapshot evidence: temporary directory `recorder-checks-B6BE1817-5E79-4008-A1B5-438AC2CC0D96` printed by the final check. It includes dark/light **620-point-wide** library/playback layouts with ten long tags and a long title, plus recording, saving, error, and microphone/recovery states. The older 760-point playback snapshot did not establish minimum-width behavior.
- `zsh Scripts/check-transport.sh`: 1,280,000 frames moved concurrently between producer and consumer with exact stereo/microphone ordering. Ring wraparound and malformed callback handling passed under AddressSanitizer and UndefinedBehaviorSanitizer, with compiler warnings treated as errors.
- Visually inspected generated minimum-width light/dark library/playback and error images during this review. Row actions fit on separate lines, long tags scroll horizontally, source/total storage is readable, and the main content scrolls below the fixed header/footer. Screenshot inspection exposed an incorrect source-byte total, which was fixed and regression-tested.
- Property lists and shell syntax checks passed. The app bundle passed `codesign --verify --deep --strict` with an ad-hoc signature.
- A prior implementation run recorded a Launch Services startup smoke check. The newly rebuilt bundle was **not launched against the user's recording library** in this corrective run; UI checks used isolated fixtures.

The first sandboxed codec run reported insufficient disk capacity because macOS capacity services were unavailable. The same checks passed with normal macOS service access. UI snapshots use fake capture and generated audio; they do not establish physical-device behavior.

## Not yet verified

Live system/microphone capture, permissions prompts/denials, device changes, sleep, real low-disk/write failures, forced termination, four-hour recordings, and 100 hardware start/stop cycles remain unqualified. The user previously reported ordinary recording works; that is separate from this automated review. Metadata failures are injected and do not simulate actual power loss. Trash checks move generated fixtures to a separate temporary folder and restore them; a real macOS Trash move/restore remains untested. VoiceOver, complete keyboard traversal, edit/delete sheets, and native save-panel/quit dialogs need manual review. Minimum macOS and Intel support have not been tested; this local bundle is arm64.

GitHub Actions is configured but has not run. Developer ID signing, notarization, clean-machine installation, icon provenance, and the proposed MIT license choice require completion before a public release. Implementation files are local and have not been committed or pushed in this validation run.

See the [release checklist](release-checklist.md) for the remaining acceptance matrix. No bug-free or production-ready claim is made from these checks.
