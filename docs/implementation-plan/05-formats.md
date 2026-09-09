# Task 5 — Export formats, quality presets, and reusable rendering

Depends on shared schema/assets/retention. This task provides the pipeline reused by destination delivery, trimming, and cleanup. Refactor AudioExporter incrementally; do not discard its checked reads, full decode validation, or recovery behavior.

## User-facing settings

Provide a default recording export preset in settings, snapshotted at capture start. Also provide Export… for an existing recording with a per-operation preset. Keep the original/primary asset; an additional format export creates another asset, not an overwrite or a change of recording identity.

| Preset | Container/extension | Codec/output | Notes |
|---|---|---|---|
| Compact | M4A / `.m4a` | AAC, 48 kHz stereo, 128 kbps | Smaller file |
| Balanced (default) | M4A / `.m4a` | AAC, 48 kHz stereo, 192 kbps | Preserve current default |
| High quality | M4A / `.m4a` | AAC, 48 kHz stereo, 256 kbps | Larger lossy file |
| WAV | WAVE / `.wav` | Signed 24-bit PCM, 48 kHz stereo | Large, uncompressed |
| Apple Lossless | M4A / `.m4a` | ALAC, 24-bit, 48 kHz stereo | Lossless encoding of rendered PCM |
| FLAC | FLAC / `.flac` | FLAC, 24-bit, 48 kHz stereo | Enable only when capability probe passes |

No MP3, arbitrary codec strings, arbitrary sample-rate editor, or mono export in this scope. Keeping stereo/output rate fixed reduces combinations while delivering useful choices. “Lossless” describes the codec; it cannot undo earlier AAC compression, gain changes, mixing, or sample-rate conversion.

## Capability handling

The 2026-09-09 local encoder query advertised PCM/AAC/ALAC/FLAC, not MP3. This was an enumeration, not an end-to-end qualification of every new preset and OS.

- Use AudioToolbox's encode-format/container capability queries. Do not assume a known file extension means an encoder exists; MP3 containers may be listed without an MP3 encoder.
- Query/configure supported bitrates and channel/rate combinations, then write, close, and fully decode a small generated fixture for every exposed preset on the development machine and CI.
- Cache capability results outside the main render path. Unsupported preset: disable it with a reason; a persisted unsupported default should show a visible fallback to Balanced, never silently mislabel a file.
- A request already in progress fails clearly if its encoder becomes unavailable. Do not output another codec under the requested extension.
- Do not require a microphone or live system capture to probe codecs.

## Refactoring map

1. Add strongly typed `ExportPreset`/`AudioOutputFormat` in RecorderCore: identifier, extension, content type, file type, codec intent, rate, channels, sample precision/bitrate, estimate policy. Keep AudioToolbox-specific constants in RecorderAudio where practical.
2. Replace AudioFileWriter's `compressed: Bool` switch with an explicit writer configuration. Keep the raw CAF writer path unchanged. Construct proper container/codec ASBDs using the SDK's format-info helpers and flags; ALAC is not AAC with a different extension, and FLAC is not WAV.
3. Extract the existing validated segment reader/mixer into a reusable bounded source reader. Add a saved-asset reader for legacy/derived recordings. Do not impose the raw segment 35-second limit on a completed multi-hour asset.
4. Introduce immutable RenderRequest and a result describing a validated temporary artifact. Separate rendering from SessionStore commit/delivery. Capture completion, additional export, derived recording, and preview have different owners/commit policies.
5. Parameterize validation by requested format. Read actual file codec/container and decoded PCM properties; M4A AAC and M4A ALAC must be distinguished.
6. Update every hard-coded `Recording.m4a`, `.mpeg4Audio`, 48 kHz/2-channel validation constant where it describes an asset rather than the deliberately fixed output contract. Source rates remain variable; never pretend a 16 kHz source is 48 kHz before resampling.
7. Route playback, Show in Finder, Save Copy, export selection, details, and file-size estimates through asset metadata/resolution. Keep legacy Recording.m4a working through the migrated primary asset.

## Processing and validation contract

Read source -> optional source-range selection -> explicit source mixing/resampling/processing -> peak analysis -> encode -> close/synchronize -> full decode -> commit. Processing options default off; preserve the existing mix/headroom behavior for a normal Balanced export.

For a raw capture, system and microphone remain aligned on the saved frame timeline. Complete captures require every expected frame. Partial recovery may fill known missing portions as the existing recovery policy specifies and remains labeled partial. Do not silently omit an entire missing segment from a complete session.

Continue the current safe gain policy: no unnecessary amplification, reduce overly high peak to 0.8 before final encoding, validate decoded peak <= 0.99, and at most one controlled lower-gain retry for codec/resampler overshoot. Later cleanup normalization computes its gain before this final safety check; it does not remove the output guard.

Validate: file can be opened, actual codec/container match, 48 kHz/two channels match, duration corresponds to requested source frames, all expected decoded frames are readable, samples finite, and peak safe. For lossless output, aim for resampling-length agreement within one output frame after proper converter flushing. For AAC, account for priming/padding/gapless metadata and use an explicitly documented decoded-duration tolerance no looser than the existing 0.1 second. Tests must check actual audible start/end content as well as duration. Flush converters completely; do not treat an early nil buffer as successful EOF.

Size estimate: PCM uses duration * outputRate * channels * bytes/sample plus headers; lossless compression reserves at least an uncompressed-size estimate plus overhead; AAC uses bitrate/8 * duration plus margin. Account for each simultaneous temporary/intermediate/internal/external copy and per-volume available capacity. Fail before work where possible; handle real ENOSPC/write/close failures regardless of estimates. Do not reuse the old AAC-only estimate for WAV or RNNoise intermediates.

All long operations are cancellable between bounded chunks. Progress stages reflect actual work; a second encode pass cannot display “done” before validation. An additional export failure leaves the prior primary asset and session ready/partial status intact. Keep sources retained as required by task 0.

## Tests

- For each exposed preset, export/decode generated stereo tones and verify codec, rate, channels, duration, readable frames, peak, and correct extension.
- Distinct left/right and opposite-phase signals remain distinct; 16 kHz and 44.1 kHz sources resample to the expected 48 kHz duration.
- Quantization tests for 24-bit lossless formats use appropriate numerical tolerance; do not compare encoded file bytes across codecs.
- Legacy M4A-only session can play/re-export; UI states that a lossless container does not restore lost source quality.
- A retained source missing/corrupt file fails without quietly falling back to a legacy/lossy copy.
- Short, long, silent, loud (>1 peak), partial, multi-segment, and nonfinite/corrupt inputs have explicit expected outcomes.
- Cancellation/write/close/validation/metadata commit failures preserve the previous asset and all sources. Test the promoted-but-uncommitted pending-job recovery path.
- Request WAV while AAC is the default; actual output is WAV, not a renamed M4A. Request ALAC; verify it is not AAC.
- Test memory remains bounded across a generated long file and handle count does not grow per segment.
- Test codec unsupported and insufficient-space paths through injected capability/capacity services.

References: [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile), [AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter), [ExtAudioFile](https://developer.apple.com/documentation/audiotoolbox/extended_audio_file_services). Inspect the local AudioToolbox headers for exact codec flags; do not guess ASBD fields.
