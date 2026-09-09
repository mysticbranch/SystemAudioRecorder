# Release qualification

This checklist distinguishes implemented behavior from validation still required. A compiled or ad-hoc signed build is a development preview.

## Automated checks

Run `zsh Scripts/check.sh`. The standalone Swift runner returns nonzero on failure and prints its temporary evidence directory. It covers input limits, recording phases, storage recovery, malformed metadata, transport ordering/overflow/discontinuity, stereo export, peak headroom, sample-rate conversion, multiple segments, partial recovery, source corruption, cancellation, and controller re-entry.

Run `zsh Scripts/check.sh --ui-snapshots` with a GUI session for images of idle, recording, saving, and error states. Inspect minimum and normal window sizes. Screenshots with fake capture establish layout/state behavior, not live recording correctness.

## Hardware and lifecycle matrix — requires manual qualification

- [ ] System-only capture: browser audio, silence, and alternating left/right test signal.
- [ ] System + built-in microphone: both sources audible, correct pitch/duration, no unexpected drift.
- [ ] USB mono/stereo microphones and supported sample rates.
- [ ] Bluetooth microphone/headset, including profile changes.
- [ ] Unsupported multichannel/noninterleaved layouts produce an actionable error.
- [ ] First-use and denied system/microphone permissions; system-only works with microphone access denied.
- [ ] Device disconnection, default output changes, sleep/wake, and permissions changing.
- [ ] Low disk and unwritable storage: incomplete outcome, recoverable sources, UI remains usable.
- [ ] Quit/window close while recording: both cancel and stop/save paths.
- [ ] Quit while preparing, stopping, and saving.
- [ ] Forced termination during capture and export; next launch exposes recovery.
- [ ] 100 start/stop cycles with no accumulating devices, files, or callbacks.
- [ ] Four-hour recordings for principal supported device classes; measure drift, memory, CPU, and power use.

## Interface — requires visual and accessibility review

- [x] Minimum and normal sizes; light/dark appearance (generated state snapshots; see validation record).
- [ ] Long device names, long error messages, many recordings, and unavailable microphone selection.
- [ ] Scrolling and keyboard access to every action; paste/select-all in time field.
- [ ] VoiceOver labels, focus order, state announcements, and source meters.
- [ ] Save-copy cancellation, overwrite confirmation, playback completion, and missing output files.
- [ ] Recovery, partial recordings, and unreadable session folders are distinguishable.

## Distribution

- [ ] Confirm minimum macOS version with an actual machine/VM and supported CPU architectures.
- [ ] Confirm source and carried-over icon provenance and license choice.
- [ ] Enable GitHub private vulnerability reporting.
- [ ] Run GitHub Actions on the published branch.
- [ ] Developer ID signing, hardened runtime, notarization, stapling, and Gatekeeper assessment.
- [ ] Install the exact downloaded artifact on a clean Mac without Python/development tools.

Keep a release-specific record of which OS/device combinations passed and any remaining limitations. A failing or untested critical item prevents describing the build as production ready.

## New workflow qualification — manual checks still required

- [ ] Physical capture pause/resume: silence, microphone, long pauses, 100 cycles, changed/default/disconnected devices, stop/quit/sleep during transitions.
- [ ] All presets on macOS 14.2 and Intel; long WAV/ALAC/FLAC outputs near container/file-size limits.
- [ ] Folder panel cancellation, bookmark movement, unmounted drives, real low/full/read-only volumes, collision races, and quit during delivery.
- [ ] Force terminate during processing, promotion, and copy; retry without duplicate assets or loss of original recordings.
- [ ] Trim and cleanup sheets with keyboard-only navigation and VoiceOver, long errors/titles, light/dark mode, smallest supported display.
- [ ] Headphone listening: original/processed speech, accents, quiet/loud voices, steady and transient noise, silence, music, and stereo imaging. Synthetic noise reduction is not proof of intelligibility or artifact-free speech.
- [ ] Four-hour offline processing: peak memory, temporary disk consumption, CPU, cancellation latency, file handles, and power.

Run `zsh Scripts/check-rnnoise.sh` alongside the transport sanitizer checks. The RNNoise source/model notices are bundled; carried-over icon provenance remains a separate release item.
