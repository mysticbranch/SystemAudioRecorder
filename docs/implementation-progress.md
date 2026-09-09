# Recording workflow implementation status

2026-09-09. Task classification: new features, changes to existing functionality, bug fixes, and supporting modular refactoring. Scope: the eight capabilities in the handoff; transcription, MP3, and unrelated product ideas are excluded.

## Implemented locally

| Capability | Implementation | Evidence / limits |
|---|---|---|
| Recording pause/resume | Explicit lifecycle, graph recreation with original microphone UID/format, lazy segment boundaries, captured-frame clock/limit, queued Stop during transitions, paused crash recovery | Real CaptureService with scripted transport: boundaries, zero frames, 100 cycles, frame limit, changed rate, write/close failure. Physical devices pending. |
| Playback controls | Existing seek, skip, rate, volume, pause/resume controller; shared preview playback | Existing actual-player and injected callback/state regressions pass. Keyboard/VoiceOver qualification pending. |
| Library organization | Existing names, tags, favorites, search, sort, metadata patching, background refresh | Existing migration, stale-scan, metadata, and 1,000-record checks pass. |
| Delete recording | Existing confirmed whole-session Move to Trash; independent clips and external copies remain separate | Generated-fixture failure/cancel/restore checks pass. Real Trash was not used. |
| Trim and clips | Strict time parsing, frame ranges/sliders, preview, independent clip with provenance | Cross-segment cuts at 16/44.1/48 kHz, exact PCM length, unchanged parent, re-export after parent fixture removal. |
| Export folder and naming | Bookmarks, settings draft, default preset, filename tokens/Unicode bounds, automatic copy, collision suffixes, SHA-256 retry adoption | Invalid destination leaves internal success; collision/adoption/bookmark tests pass. Physical drive/full-volume cases pending. |
| Formats and quality | AAC 128/192/256 kbps, WAV PCM 24-bit, ALAC 24-bit, FLAC 24-bit, per-launch capability probes, generic validation/commit | All six presets write and decode with actual codec/precision checks on this Mac. Minimum OS/Intel pending. |
| Optional cleanup | Default-off 80 Hz rumble filter, pinned offline RNNoise, bounded fixed-gain active-RMS leveling, microphone/whole-mix target, original/processed preview, independent cleaned copy | Frequency response, level limits, stationary-noise reduction, short/tail frame counts, untouched system alignment, native memory checks pass. Speech intelligibility/listening pending. |

## Safety and structure

Shared `RenderRequest`, source reader, processor, writer/validator, and commit code serve capture export, additional formats, clips, cleanup, and preview. Rendering stays off the main actor and capture callback with bounded buffers and temporary-disk estimates. Original sources remain retained. Lossy source provenance stays visible.

Durable render intent makes interrupted offline work retryable without replacing the owner or settings. Validated asset promotion has a separate synchronized journal and idempotent metadata recovery. External delivery starts from a committed asset and has independent failure/retry state. Generated temporary paths and preview ancestors reject traversal/symlinks. Pending delivery notices follow library refresh and Trash.

RNNoise is isolated in a pinned C target with source/model checksums, documented local initialization/allocation patches, sanitizer checks, and bundled upstream notices. No global packages, runtime downloads, or network audio processing were introduced.

## Verification actually completed

- `zsh Scripts/check.sh --ui-snapshots`: **62 passed, 0 failed**, retaining the 41-check corrective-review baseline and adding 21 workflow checks.
- `zsh Scripts/check-transport.sh`: 1,280,000 concurrent frames; AddressSanitizer/UndefinedBehaviorSanitizer passed.
- `zsh Scripts/check-rnnoise.sh`: pinned source/model checksums, four concurrent initialization/processing workers, independent states and finite output; AddressSanitizer/UndefinedBehaviorSanitizer passed.
- `zsh Scripts/build-app.sh`: arm64 release executable and local ad-hoc signed app built successfully. Previous app retained at `.build/bundle.JMuWHV/previous.app`.
- Strict bundle signature verification passed; packaged third-party notices exactly match source.
- Property-list and shell syntax checks passed. Generated trim/cleanup/settings sheets and paused layout visually inspected; persistent time/pattern labels added after screenshot review.
- Latest fixture/snapshot evidence: temporary folder `recorder-checks-1A530E94-8C01-47E1-91A2-2C8C99E72F61`, printed by the runner.

## Not verified / release limits

No live capture, private audio, real Trash operation, external account writes, commits, or pushes were used in this work. The newly built app was not launched against the user's recording library; view/controller verification used isolated generated fixtures. Ordinary recording working was previously reported by the user, not re-established here.

Physical pause/resume, sleep/device/permission changes, four-hour recording/render performance, speech/music listening quality, full keyboard/VoiceOver navigation, native picker interaction, real full/unmounted drives, and forced-termination/power-loss testing remain manual gates. Failure injection and staged journals do not establish actual power-loss durability on every filesystem. A process crash during preview may leave a disposable preview folder; automatic stale-preview pruning is not implemented.

Minimum macOS 14.2, Intel, GitHub CI execution, Developer ID/notarization, clean-machine installation, and carried-over icon provenance remain release work. Source files were untracked at the start and remain local/uncommitted. See `release-checklist.md`; this is not a bug-free or production-ready certification.
