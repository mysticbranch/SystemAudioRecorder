# Task 4 — Pause and resume recording

This is the highest-risk capture change in this group. Read CaptureService, CaptureGraph, and the C transport before editing. Preserve the working capture format checks and real-time constraints.

## User contract

- Recording shows Pause and Stop and save. Pause transitions through Pausing to Paused.
- Paused shows a frozen captured duration, zero/quiet meters, Resume, and Stop and save. It does not say Ready and does not allow another recording.
- Resume transitions through Resuming and continues the same session UUID into a new source segment.
- Audio between successful Pause and the start of resumed capture is absent from saved audio. Capture is actually stopped while paused; do not merely ignore audio while leaving the recording graph running.
- Captured duration, automatic stop, segment positions, and future bookmark times exclude paused wall time. Example: record 10 seconds, pause 60 seconds, record 5 seconds -> approximately 15 seconds of audio, not 75.
- Settings stay locked while paused. Resume with an unavailable/incompatible device fails visibly and keeps the already-recorded audio recoverable.
- Stop while paused finalizes the existing session without restarting the graph. A healthy recording may then export normally.
- Quit while paused offers Stop, Save and Quit or Keep Recording, just as active recording does. Sleep while paused ends the session as interrupted; it does not resume capture automatically on wake.

## Chosen architecture: new graph for each resumed interval

Do **not** add a reversible accepting flag to the current C ring. `recorder_transport_stop` is terminal, and timestamps/rate identity are per graph. Recreate CaptureGraph and its ring on resume, while preserving the CaptureService session and accumulated recorded-frame counter.

Add `pause()` and `resume()` async throwing operations to `Capturing`, plus a returned snapshot carrying session ID, capture state, and cumulative recorded frames. Update FakeCapture and all conformances. A narrow internal graph/writer factory seam should allow tests to exercise the real CaptureService with deterministic devices and write failures; do not test only RecorderModel with FakeCapture.

Give CaptureService an explicit lifecycle (`idle`, `recording`, `paused`, transitions, terminal/failed as needed). A nil graph no longer means a new recording may start: paused capture has no graph but still owns a session. Reject invalid commands before any cleanup/mutation, so duplicate start cannot finish an older session.

## Pause algorithm, on the existing serial control queue

1. Check lifecycle is recording; claim pausing. Cancel the drain timer so no second tick can interleave. Already-enqueued tick closures must check lifecycle/generation.
2. Call graph.detach: stop accepting samples and detach the Core Audio callback using the existing safe ownership rules.
3. Inspect transport faults, drain accepted pre-pause samples, close/check/synchronize both segment writers, and persist their frame counts.
4. Close the graph and release it only after successful detachment. A cleanup failure must retain unsafe-to-free resources and block unsafe restarts, as today.
5. Persist session status paused, captureCompleted false, with no added pause-length segment. Preserve its accumulated source duration.
6. Publish paused snapshot only after these steps succeed. Do not convert a failed close/save into an apparently healthy pause.

Refactor shared teardown helpers from `finish` as needed, but do not call `finish(reason:nil)` to implement pause: it marks capture complete and clears the event owner. On any transition failure, run terminal cleanup once, preserve the first cause, persist interrupted if possible, and let the UI expose recovery. Make terminal cleanup idempotent for a given session so error paths do not export or close twice.

## Resume algorithm

1. Only paused may resume. Check cancellation/shutdown intent before allocating new hardware.
2. Re-resolve the microphone by the stable device UID captured on initial start, including when System default was selected. Do not silently switch to a new default microphone or trust a reused numeric AudioObjectID.
3. Build a new CaptureGraph. Require the original capture sample rate and channel/source layout. If they differ, close the new graph, end as interrupted, and ask the user to start a new recording. Do not append incompatible PCM to this session.
4. Recheck disk headroom. Open/journal the next segment at `startFrame = cumulativeRecordedFrames`, then start the graph.
5. Reset graph-local transport counters, liveness/watchdog timestamps, and timer generation; do not reset cumulative recorded frames, selected source identity, or maximum duration.
6. Mark recording/persist state, start the drain timer, and return the new snapshot. Check stop/shutdown intent again so quitting while resuming cannot leave a newly started graph behind.

## Frame accounting and timer changes

- Rename or clearly document CaptureService.acceptedFrames as cumulative successfully written frames. The C transport's accepted_frames is graph-local delivery data only.
- UI elapsed = cumulativeRecordedFrames / originalSampleRate. Keep saved segment startFrame continuous across pauses.
- Maximum duration becomes a frame limit computed once using the original sample rate with finite/overflow checks. Paused time never consumes the limit.
- Cap each write at the remaining frame budget. When it reaches zero, request a normal stop once; discard later queued samples rather than accidentally appending them during final drain. Ensure count==0 cannot create an infinite drain loop.
- Maintain real-time discontinuity checking within each graph. A new ring naturally starts a new device timestamp sequence on resume; it must not create a gap in the saved timeline.
- If pause occurs exactly on a 30-second segment boundary, avoid leaving an extra empty segment that makes successful export fail. Open the next segment lazily on actual data where practical. If an empty tail has already been journaled, remove only that verified unwritten tail and its own empty files, then persist; never erase a segment that received any samples.
- Liveness monitoring is disabled while paused and reset on resume. Silence with valid callbacks remains valid recording, as today.

## UI/model/quit integration

Update all phase-dependent buttons, source settings, `canStart`, `canWorkWithFiles`, stop, sleep handling, operation events, and quit interception. The app's Cmd-Shift-R action remains Start when idle and Stop/save during recording or paused. Add an in-app Pause/Resume action with an accessible button; do not introduce a conflicting global shortcut.

Claim pausing/resuming synchronously in the model before awaiting service work. Do not change the active session ID. Repeated clicks are ignored/rejected predictably. Stop/quit arriving during a transition must be serialized as an intent: await transition completion and finalize once; never await the same Task from itself. If resume was cancelled after graph start, tear it down before returning idle.

## Required tests

1. Scripted real-service test: 48,000 frames, pause, arbitrary simulated wall-clock delay, resume for 24,000 frames -> 72,000 saved source frames, continuous segment start positions, no inserted silence.
2. Known tones A and B on either side: decoded output contains A immediately followed by B, preserving stereo/microphone alignment. No samples from the paused interval.
3. 100 pause/resume cycles with graph creation/destruction counts balanced and no duplicate active timers/callback owners.
4. Test at just below, exactly at, and just above the 30-second segment boundary; no harmful zero-frame tail.
5. Pause before the first audio frame; resume and record. Stop with no audio reports no captured audio, not a successful silent file.
6. A 3-second limit with a long pause still yields 3 seconds of source audio; repeated final drains do not append beyond the frame budget.
7. Disconnect/change microphone or rate while paused: resume rejects incompatible configuration and preserves earlier audio. System-default changes do not silently switch source.
8. Pause write/close/journal/detach failures each produce interrupted state and kept sources; unsafe callback memory is never freed.
9. Repeated start/pause/resume/stop calls and stale meter/stop events cannot create a second session or double-export.
10. Quit/sleep/stop during pausing/resuming and quit cancellation from paused leave controls and hardware in the promised state.
11. Simulated crash after paused manifest -> next launch exposes recovery without starting capture.
12. Manual real hardware test verifies the app's capture actually stops while paused and resumes audibly. Mocks do not establish this.

Update architecture and release-checklist descriptions to reflect graph recreation and captured-time auto-stop semantics.
