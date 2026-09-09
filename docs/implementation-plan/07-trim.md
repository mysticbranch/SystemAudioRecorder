# Task 7 — Non-destructive trimming and independent clips

Depends on library IDs, playback, shared rendering/formats, and destination delivery. Implement a focused range editor, not a multi-track waveform workstation.

## User behavior

- On a playable completed/partial recording, offer Trim / Save clip….
- Show original title/duration, Start and End time fields, a range control, resulting duration, Preview selection, output preset, clip title, Cancel, and Save clip.
- Time fields support seconds or `mm:ss[.fff]` / `hh:mm:ss[.fff]`. Reject malformed, negative, nonfinite, and overflow values; clearly label the accepted format. Do not interpret ambiguous thousands separators as decimal points.
- Require `0 <= start < end <= actual source duration` and a minimum selected duration of 0.25 seconds. Invalid input never starts a render and does not silently swap start/end.
- Default selection is the whole recording, default title `<original title> — Clip`, default output preset the user's current preference. Editing title uses the library's length/character rules.
- Preview plays only the selected range; it does not seek/edit the parent recording permanently. Keep normal playback and preview mutually exclusive.
- Save clip creates a new independent library recording with a new UUID and primary asset. Original title/audio/metadata remain unchanged.
- A clip from a partial recording remains explicitly partial with its inherited issue; creating a shorter file must not pretend the original capture was complete.
- Cancel closes the draft or cancels the pending render; no half-created ready row, no parent modification.

## Implementation approach

Add a pure `AudioTimeInput`/`AudioFrameRange` type in RecorderCore and `TrimSheet` in RecorderUI. Use the shared source resolver and RenderRequest; do not add another independent encoder.

Source choice: use retained raw segments for a capture when available by declared retention policy. Use the selected asset for legacy M4A-only or independent derived recordings. If the selected asset is not the original source, display its format/quality provenance. Outputting WAV from legacy AAC does not regain original quality.

Convert validated UI times once to `[startFrame, endFrame)` at the source sample rate: floor start, ceil end, clamp against actual known length, check Int64 conversion/overflow. Store exact frame values and the source rate in derivation metadata. Do not use AVAudioPlayer.currentTime as the saved trim boundary; playback is not an editing clock.

For segmented input, intersect the requested range with each segment's `[startFrame, startFrame + frames)` range, seek to the local start, and read exactly the overlap. The new output begins at zero. If the range crosses a pause or 30-second boundary, concatenate the stored audio timeline; insert no wall-clock gap. Reuse explicit partial-source rules; complete source read errors fail.

For a single saved asset, seek/read bounded frame ranges. Decode/re-encode AAC when necessary; do not claim arbitrary compressed cuts are bit-for-bit lossless. Validate exact source frame selection in PCM tests and codec-appropriate output duration/content in AAC tests.

Preview: render the selected range through the shared renderer into a temporary preview asset, then play it using PlaybackController. This avoids adding imprecise “stop at end” timer logic to normal playback. Large previews must be cancellable and show progress; only the newest range-generation can publish a preview. Cache a small bounded number/size of generated previews and remove them on replacement/close/shutdown. They are not library sessions and never trigger automatic external delivery.

Save: snapshot selection/title/source/preset; create a pending derived session/job; render and validate its independent file; commit only on success. Store parent ID and source range for information, not a lazy reference. If the parent is later deleted, the clip still plays and exports. If commit fails after file promotion, shared pending-job recovery applies.

## Acceptance tests

1. Select a middle range from generated distinct tone sections; verify only the intended tone/frames are present. Test source rates 16 kHz, 44.1 kHz, and 48 kHz.
2. Test boundaries at zero/end, a full-length clip, 0.25-second minimum, invalid equal/reversed bounds, NaN/infinity, and huge numeric input.
3. Cross a source segment boundary and a pause/resume boundary; no missing/duplicated frame in the selected PCM timeline.
4. Preview obeys the range; modifying range while a prior preview renders cannot play stale audio.
5. Source/parent file hashes and manifest remain unchanged after successful clip, failed clip, and cancellation.
6. New clip UUID is unique, starts at zero, has correct duration/preset/title/provenance, and appears through the normal library refresh.
7. Trash the parent fixture; clip still plays. Trash the clip; parent remains intact.
8. Legacy AAC source works with an explicit quality caveat; a corrupt source does not silently return a shortened successful clip.
9. Partial parent remains partial. Empty/unreadable recovery material cannot become a ready clip.
10. Failed write/close/validation/metadata save leaves no falsely ready item and preserves any recoverable validated output.
11. Filename/destination copy failure leaves the new internally committed clip available, with Retry external copy.
12. Check small window, keyboard time entry/paste, accessible range controls, and long title/error wrapping.

No waveform drawing, clip merging, multi-region selection, in-place overwrite, or editor undo stack is required. Non-destructive creation supplies the safety guarantee for this scope.
