# System Audio Recorder

A native macOS recorder for system audio, with an optional microphone. Recordings stay on your Mac. No Python, transcription models, account, or virtual audio driver is required.

**Development preview:** this implementation includes automated regression checks. Hardware, macOS-version, accessibility, and distribution qualification are tracked in [the release checklist](docs/release-checklist.md). Do not treat a local build as a qualified production release.

## Features

- Stereo system-audio capture through Core Audio process taps.
- Optional mono/stereo microphone, selected explicitly or through the system default.
- Recording pause/resume, elapsed captured time, source levels, and automatic stop that excludes paused time.
- Source audio saved in 30-second segments with a persistent recovery journal.
- AAC/M4A at 128, 192, or 256 kbps; 24-bit WAV, Apple Lossless, and FLAC where the native encoder probe succeeds. Every output is fully decoded and validated.
- Trim a selected range into an independent clip; preview before saving.
- Optional offline rumble reduction, RNNoise speech-noise reduction, and fixed-gain speech leveling; save an independent cleaned copy.
- Preferred export folder, filename tokens, automatic copies, collision-safe naming, and retry after delivery failure.
- Recovery of readable audio after interruption; partial results remain labeled partial.
- Local playback with pause/resume, seek, skip, speed, and playback-volume controls; Finder access; and Save a Copy.
- Recording names, tags, favorites, search, filters, sort order, and storage-use display.
- Confirmation-gated **Move to Trash** for a complete managed recording session, with no permanent-delete fallback.
- Safe stop/save on quit and interruption handling for sleep, device changes, stalled audio delivery, and low disk space.

Unsupported input layouts stop with an error instead of silently guessing. Current capture supports packed, interleaved Float32 with a stereo system tap and an optional mono/stereo microphone. Protected content and audio not delivered through the tap may be unavailable.

## Build and run

Requirements: macOS 14.2 or later and a Swift 6 toolchain (Xcode or Command Line Tools). The first validation environment is Apple Silicon; other hardware and OS versions require qualification.

```sh
zsh Scripts/check.sh
zsh Scripts/build-app.sh
open 'dist/System Audio Recorder.app'
```

The build uses project-local caches. The default bundle is signed ad hoc for local development; it is not notarized. Grant System Audio Recording permission when macOS asks. Microphone permission is requested only if you enable the microphone. The new bundle identifier is `io.github.mysticbranch.SystemAudioRecorder`, so permissions granted to an older prototype do not automatically transfer.

`Shift-Command-R` starts recording or stops and saves. Use **Pause** and **Resume** during capture; paused time is absent from the saved audio. Use a recording’s **Tools** menu for formats, trim, and cleanup. **Export settings** in the footer selects the default format, destination, and filename pattern. Space toggles loaded playback when no text editor, control, or sheet is consuming it. Saving can be cancelled; its source audio remains available for another attempt. When microphone recording is enabled, headphones reduce speaker echo.

## Files and recovery

Sessions live in:

```text
~/Library/Application Support/io.github.mysticbranch.SystemAudioRecorder/Sessions/
```

Each session has a JSON journal, numbered source segments, and a validated saved-audio asset after saving. New assets use internal generated paths; older `Recording.m4a` sessions remain readable. The UI provides **Open recordings folder**, **Show in Finder**, **Save a copy**, rich playback controls, editing for names/tags/favorites, search, tag and favorite filters, sorting, per-recording storage use, and **Move to Trash** for the managed session folder.

New recordings retain their source segments after a saved-audio asset has been fully decoded, validated, and committed. The library and details show total and retained-source storage separately. This supports later exports and editing without reducing quality. Metadata is schema-versioned; editing an older manifest first saves its original bytes as `session-v1.backup.json`. Existing M4A-only recordings remain as they are. Unreadable session folders are reported and preserved. Interrupted offline renders retain their settings and reuse the same library entry on **Finish saving**. If an export's audio is saved but its metadata cannot be committed, a journal preserves that output and the library offers **Finish saving**; retry fully validates the file before committing it. Recovery is best effort: a crash or power loss can lose data not yet written or finalized, particularly the active segment and buffered audio.

The compact M4A size is not the recording-time storage requirement. For example, 48 kHz Float32 stereo plus mono microphone uses about 2.07 GB/hour before export. Free-space checks include uncompressed working audio, processed audio, output validation/re-encoding, and a reserve. Long exports need substantially more free space than the final compressed file. Use the recordings folder to manage unwanted sessions carefully.

## Development

See [architecture](docs/architecture.md), [contributing](CONTRIBUTING.md), [repository setup](docs/repository-setup.md), and [release checks](docs/release-checklist.md).

The initial [validation record](docs/validation.md) lists completed checks and remaining release gates. Run `zsh Scripts/check-transport.sh` to stress the concurrent C audio buffer and `zsh Scripts/check-rnnoise.sh` to verify the pinned denoiser checksums and native ownership under AddressSanitizer and UndefinedBehaviorSanitizer.

`Scripts/check.sh` runs a standalone Swift regression executable and configuration checks. It needs no XCTest installation. The checks use temporary generated audio and fake capture for UI state transitions; they do not record your microphone or system audio. macOS media-service access is required for AAC tests. `--core-only` runs storage, validation, and transport checks without codecs. `--ui-snapshots` additionally opens temporary test windows and writes UI screenshots into the printed temporary directory.

## Distribution

Public downloadable builds require an appropriate Developer ID identity and an existing notarytool Keychain profile:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE='your-existing-profile' zsh Scripts/release.sh
```

This runs checks, builds with hardened runtime, notarizes, staples, verifies Gatekeeper acceptance, and produces `dist/SystemAudioRecorder.zip`. It does not upload a GitHub release. Signing does not implicitly enable App Sandbox. This first direct-distribution build uses the normal macOS privacy protections; an App Store/sandbox target is separate future work.

## Privacy

The recording-only app has no network client or analytics. It does not download models or launch a Python worker. Audio is saved under your user account in a private session directory. The bundled RNNoise model runs offline; its source, pin, and notices are documented in [Vendor/RNNoise](Vendor/RNNoise/README.md). A chosen external export folder may be synced by other software. Get permission from people you record.

## License

Application code: MIT. See [LICENSE](LICENSE). Bundled RNNoise retains its upstream BSD-style terms; see [third-party notices](Resources/ThirdPartyNotices.txt). The app icon was carried over from the original personal prototype; confirm its provenance before publishing downloadable releases.

## Cleanup and export behavior

Cleanup defaults off. For retained microphone recordings, rumble/noise processing defaults to the microphone track; the system track stays unchanged before mixing and final gain. Normalization adjusts the whole final mix to a bounded active-RMS target, not LUFS or dynamic compression. Speech processing can alter music and voice timbre; use Original/Processed preview before saving. Preview covers up to 15 seconds; saving processes the full recording. Listening qualification is still pending.

Clips and cleaned copies have independent files. Deleting their parent does not delete them. Re-exporting an old AAC recording as WAV or FLAC cannot restore previously lost detail. MP3 is not included.

The chosen save folder receives copies; it does not replace the app’s internal recovery storage. Filename tokens are `{date}`, `{time}`, `{title}`, and `{id}`. An external-copy failure leaves the internal recording usable and exposes Retry; existing destination files are never overwritten by automatic delivery. Move to Trash removes only the selected internal session, including its additional exports, and leaves external copies alone.
