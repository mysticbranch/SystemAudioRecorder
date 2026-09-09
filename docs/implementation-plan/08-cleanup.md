# Task 8 — Optional offline audio cleanup

Depends on shared rendering, playback/preview, formats, and independent derived recordings. This task must never alter live capture or overwrite a user's source audio.

## Required user workflow

Offer Clean up audio… on a completed playable recording. Open a sheet with source/target selection, Reduce rumble, Reduce speech noise, Normalize speech level, an Original/Processed preview switch, output preset, cleaned-copy title, Cancel, and Save cleaned copy.

All processing options default off. No automatic cleanup is applied to new recordings. Controls must state which audio they affect. A recording containing music must not have speech processing silently enabled.

Targets:

- If separate retained microphone audio exists, default target is Microphone only. Keep system audio untouched until the normal source mix/final headroom stage.
- Entire recording is an explicit alternative. For a system-only/legacy mixed/derived recording, it is the only available target; label it clearly.
- Do not show Microphone only for a legacy M4A whose separate sources were deleted. There is no source-separation model in this task.

Original/Processed preview uses the same source range and playback volume/rate, one player at a time. Generate a bounded preview range (default first up-to-15 seconds, adjustable start); use up to one second of preceding audio as pre-roll for stateful processing and trim it from playback. At the file beginning there is no preceding audio. Saving the full cleaned recording processes the full source, not just the preview. Explain these two scopes in the sheet.

Save creates a new independent session, default title `<original> — Cleaned`, with derivation/settings recorded. Preserve partial status/issues if the source was partial. Parent audio is immutable and remains available regardless of processing failures or cancellation.

## Components and processing order

Add a small `AudioProcessingOptions` value type and bounded processor interface under RecorderAudio. A processor owns its state for one render. It is never shared concurrently between previews/jobs.

Recommended order:

1. Resolve/validate source and selected target; work in Float32 PCM.
2. Resample target stream to 48 kHz using AVAudioConverter with a checked streaming input/output loop and proper end-of-stream flushing.
3. Optional 80 Hz high-pass for rumble reduction.
4. Optional RNNoise speech denoising.
5. Mix processed microphone with the untouched system source if target is Microphone only; align both to the same output timeline. Entire-recording processing operates on the mixed stereo stream.
6. Optional fixed-gain speech normalization measured on this processed mix.
7. Existing final peak/headroom protection, format encode, full decode validation, and independent derived-session commit.

Avoid duplicate resampling when the source is already 48 kHz. Keep state across every block and raw segment boundary. Never run this chain in AudioTransport's C capture callback. Heavy work remains cancellable and off MainActor.

When all options are off, bypass processor stages completely and use the ordinary renderer for that source/range. Do not introduce a denoiser, filter, or extra lossy generation into a nominally bypassed path.

## Rumble filter: precise first version

Use a simple, documented first-order high-pass per channel at 80 Hz, with independent state:

```text
RC = 1 / (2 * pi * 80)
alpha = RC / (RC + 1 / sampleRate)
y[n] = alpha * (y[n-1] + x[n] - x[n-1])
```

Use sufficient numerical precision for coefficients/state, reject nonfinite input/output, and retain x/y history between blocks/segments. Initialize once per render/pre-roll. This is a modest rumble filter, not an equalizer or an echo canceller. Apple Audio Units/offline AVAudioEngine could provide later richer effects, but a small tested processor avoids unnecessary graph/lifecycle complexity for this exact filter.

## Normalize speech level: bounded fixed gain

This control means measured whole-recording level adjustment, not a dynamic compressor or standards-compliant LUFS normalization. Label it accordingly.

- Measure non-overlapping 20 ms windows at 48 kHz on the processed final mix. Window power is sum(sample^2) / (frames * channels), using Double accumulation and the real frame count for the last short window.
- Treat windows with RMS >= -50 dBFS (power >= 1e-5) as active for this initial level estimate.
- Active RMS = square root of the combined active-window energy divided by combined active sample count. Target is -20 dBFS RMS (linear amplitude 0.1).
- Desired gain = 0.1 / activeRMS. Limit upward gain to +12 dB and limit output peak to 0.8. If no active windows or no nonzero signal exist, use gain 1; never divide by zero or amplify near-silence into loud noise.
- Apply one gain to the whole final mix, preserving stereo balance. This does not promise equal volume for every speaker or every sentence.
- Two-pass analysis must produce the same audio stream both times. For expensive stateful denoising, write a checked temporary processed Float32 CAF, measure it, then encode from it. Include that intermediate's full uncompressed size in disk checks; do not buffer a multi-hour file in RAM.

Output validation's decoded peak guard still applies after AAC/resampling overshoot. Gain settings and measured results belong in the derived asset metadata, not the parent session.

## Speech noise reduction: RNNoise integration

Include Reduce speech noise as an optional user-controlled mode, default off. It is a separate implementation milestone within this task; do not claim it exists if only the high-pass filter is implemented. If dependency acquisition/build is blocked, mark this subfeature incomplete explicitly.

Use the upstream RNNoise C library, not a Python subprocess or a runtime shell command. Before importing it, select and record a concrete immutable upstream revision, source/model checksums, exact source/model license notices, and reproducible build instructions. Do not depend on a moving `main` checkout in CI. Inspect upstream build files to select required sources/generated model data; do not guess the C source list or omit required weights.

Keep vendored sources or pinned build artifacts inside this project and integrate them as a dedicated C target/module. Supply the same pinned model for local/CI builds. Dependency preparation may require network access, but the distributed app must process offline without downloading models. Do not install libraries into global Python/Homebrew environments or require a development toolchain on the user's Mac.

Required wrapper behavior:

- Use the pinned header's supported API: create/init state, get frame size, process frame, and destroy state on all paths. Check allocation failures. Never share one state between channels or concurrent renders.
- The upstream demo processes 48 kHz mono frames and uses float sample values on the 16-bit PCM amplitude scale. Convert the app's normalized Float32 samples to/from that expected scale; passing [-1,1] directly without scaling is a common integration bug. Do not cast to Int16 and clip/quantize the source accidentally.
- Get the frame size from the API where available rather than scattering a magic frame count through Swift. The inspected demo uses 480 samples; pin-specific code/header is the authority.
- A mono microphone uses one state; stereo target uses independent channel states and must retain stereo identity. Never collapse the entire system recording to mono merely to call RNNoise.
- If input exceeds the model's safe nominal amplitude range, apply a documented fixed pre-attenuation determined from a source scan; preserve original files and report processing settings. Do not silently hard-clip.
- Buffer partial frames across input blocks; zero-pad only the final processor input. Determine the pinned implementation's latency, compensate alignment, flush the tail, and emit exactly the intended processed-audio duration. The demo skips its first output frame; copying that behavior without tail flushing would shorten every recording and misalign a microphone/system mix.
- Align denoised microphone and untouched system audio before mixing. Account for resampler and denoiser delay once, not per segment.
- Denoising should not mute a track merely because the library returns a low speech-probability score. Use the denoised audio output, not a home-made speech gate.
- Retain all upstream source/model license notices in the distributed notices/resources. Add a capability/availability message if the bundled processor cannot initialize; never substitute a different algorithm and still label it RNNoise.

References: [RNNoise project](https://github.com/xiph/rnnoise), [public API header](https://github.com/xiph/rnnoise/blob/main/include/rnnoise.h), [demo showing framing and sample scale](https://github.com/xiph/rnnoise/blob/main/examples/rnnoise_demo.c). These links locate upstream sources; implementation must pin a revision, and must verify its exact latency/framing behavior rather than assuming future main is identical.

## Preview and commit rules

- Reuse the shared preview/render pipeline and PlaybackController from tasks 3/7. Do not build another AVAudioPlayer in this sheet.
- Include source identity, range, processor version/model, and settings in the preview cache key. Change settings/range -> cancel/obsolete the old generation; a late processed preview cannot start playing.
- Use the same algorithm, parameters, and pre-roll rules for preview/full processing. For stateful noise reduction, a short preview may have different long-term history than a full render; do not promise sample-identical output. Align time and disclose preview scope.
- Disable Save until settings/source/range validate. On Save, snapshot all settings; progress shows processing and validation, with responsive cancellation.
- Saving full output never replaces the parent's asset. A failed external copy after internal commit leaves a playable cleaned recording.

## Acceptance tests

1. Options off: PCM renderer output matches the unprocessed pipeline within its existing conversion tolerance; no extra filtering or gain.
2. High-pass: synthetic low-frequency signal is attenuated more than an in-band tone; state/block partitioning does not change output; stereo channels remain independent.
3. Normalization: known active RMS approaches target within tolerance unless the peak/+12 dB cap applies. Silence/near-silence stays quiet, NaN/infinity fail, and output peak stays safe.
4. RNNoise: a generated/licensed speech-plus-noise fixture produces a valid full-duration output with reduced noise in a known noise-only region. Listen for intelligibility/artifacts; a file-size or nonzero-sample assertion is not a quality test.
5. Non-multiple-of-frame inputs, inputs shorter than one processor frame, final tails, 16 kHz input, and multiple source segments produce correct duration and alignment. Verify pinned processor latency explicitly with suitable known signals/source analysis.
6. Microphone-only cleanup leaves system source samples untouched before mix/headroom; no delayed microphone/doubled source due to channel mismatch.
7. Stereo whole-recording processing preserves distinct left/right content. Music processing remains explicitly opt-in, never automatic.
8. Preview cancellation/settings changes cannot publish stale audio or leak player/timer/temp files.
9. Parent hashes/metadata unchanged after success/failure/cancel. Delete parent fixture; cleaned copy still plays.
10. Inject processor allocation, resampler, write, close, low-space, codec, and metadata failure; preserve source and valid pending outputs per shared contracts.
11. Long generated input has bounded memory and bounded open descriptors; compare performance with cleanup off/on and document it without inventing real-time guarantees.
12. Manual listening and UI review includes headphones, quiet/loud speech, steady noise, silence, stereo material, and a partial recovery source. Record which cases were actually checked.

Deliver updated Package/build/CI/notices for RNNoise, processor tests, and an explicit capability table. Do not describe unfinished denoising as complete because simple normalization works.
