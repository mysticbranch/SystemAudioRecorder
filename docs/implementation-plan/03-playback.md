# Task 3 — Playback controls

Depends on shared asset resolution and stable library IDs. This task is playback pause/resume; it is separate from recording pause/resume.

## Required controls

One player panel for the selected playing recording/asset, with its title, Play/Pause, Stop, seek slider, elapsed/total time, backward 10 seconds, forward 10 seconds, playback speed, and playback volume.

- Speeds: 0.5x, 0.75x, 1x (default), 1.25x, 1.5x, 2x.
- Volume: 0–100%, default 100%. This affects playback only, never stored audio, export level, or Mac system volume.
- Start a different recording: stop/release the prior player and begin the newly requested one from zero.
- Pause: preserve position. Stop: reset to zero and remain stopped. Natural completion: show total duration and Play; the next Play starts from zero.
- Seek while paused stays paused; seek while playing resumes from the selected position. Clamp skip/seek to [0, duration].
- Rate can be remembered as a preference, but changing it never changes displayed file duration or trim timestamps.
- When search hides the playing row, keep the player title visible. The player ID is not implicitly replaced by a new selection.

## Implementation

Extract `PlaybackController` from RecorderModel. Make it MainActor-isolated and observable, owning the sole AVAudioPlayer, timer, player-generation token, and explicit state (`stopped`, `playing`, `paused`, `finished`, `failed`). The model/UI issues commands; views do not create players or timers.

Use the existing AVAudioPlayer rather than replacing the capture engine or adding a playback library:

- Resolve the validated selected asset URL through SessionStore.
- Set `enableRate = true` before preparation/play, then assign selected rate.
- Use `currentTime`, `duration`, `volume`, `play`, `pause`, and `stop` with documented semantics.
- Refresh progress around 10 times/second only while playing. Cancel/invalidate the timer when stopped, paused, changed, deleted, or shut down.
- Handle finish/decode errors through AVAudioPlayerDelegate and/or checked polling, hopping to MainActor safely. Tag callbacks with the generation so an old player cannot stop a new one.
- Use player time as source of truth; do not estimate position by adding timer intervals or multiplying a wall clock by playback rate.
- Never silently start playback after a failed `play()` or missing/corrupt file. Show the affected asset's name and a useful error.

Scrubbing: while dragging, display a draft position and suspend automatic slider updates. Commit the seek at the end of dragging. Keyboard/accessibility slider changes must also commit even without a mouse-drag callback; provide one shared seek command. Do not fight the user's slider with the playback timer.

Keyboard behavior: Space toggles playback only when no text field/editor/sheet is consuming text and no recording action is active. Do not install a global keyboard hook. Every button and slider needs an accessible label/value and focusable control. Preserve Cut/Copy/Paste/Select All for library/title/time fields.

Playback is blocked during all capture states including paused, and during render/copy/delete jobs. Starting capture stops normal/preview playback before requesting capture. Offline cleanup preview later reuses this controller; never permit two simultaneous players.

## Validation

1. Use an actual generated audio file for AVAudioPlayer integration: load, play, pause, seek, rate, volume, stop, completion. Fake-player tests alone are insufficient.
2. Unit-test the command/state layer with an injectable player adapter and controllable progress source; no multi-second sleeps to test every state transition.
3. Pause freezes the position; resume continues, Stop resets, natural finish replay starts at zero.
4. Seeking before zero/after duration clamps; NaN/infinity are rejected. Seek from a paused state does not autoplay.
5. Selecting B after A prevents A's delayed callback from changing B's state.
6. Progress remains in source-audio seconds at every rate. A 60-second file still displays 60 seconds at 2x.
7. Missing/corrupt files and unsuccessful play leave no active timer or phantom playing icon.
8. Delete or capture start stops playback. Search filtering alone does not.
9. Scrubbing does not jump backwards from a timer update; keyboard and VoiceOver adjustments seek correctly.
10. Minimum window, long title, 4-hour duration, dark/light appearance, and disabled/busy states fit without hiding controls.

References: [AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer), [rate enablement](https://developer.apple.com/documentation/avfaudio/avaudioplayer/enablerate), [currentTime](https://developer.apple.com/documentation/avfaudio/avaudioplayer/currenttime).
