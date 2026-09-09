# Integrated verification and completion checklist

This document is the implementing model's acceptance gate. Creating a UI control or compiling a file does not establish the feature's behavior.

## Work method

For each milestone: inspect affected source and current tests -> explain the small change -> implement -> run relevant checks -> review -> update progress. Keep an implementation progress note with separate **implemented**, **automated verified**, **manually verified**, and **not verified/blocked** items. Do not mark these specification files as runtime evidence.

Use the existing standalone `RecorderChecks` runner and C transport tests. Adding targeted fixtures/fakes is appropriate; replacing production behavior with test branches is not. Additional focused runner files under `Tests/RecorderChecks` are welcome. The project does not currently use XCTest as its test entry point; do not invent `swift test` success.

## Commands

From the repository root:

```sh
zsh Scripts/check.sh
zsh Scripts/check-transport.sh
zsh Scripts/check-rnnoise.sh
zsh Scripts/build-app.sh
zsh Scripts/check.sh --ui-snapshots
```

The last command opens test windows and needs a GUI session. Codec tests need normal macOS media service access. If a sandbox hides codecs/disk capacity or prevents GUI work, use the environment's normal escalation mechanism and explain the limitation; do not alter app checks or disable safety logic to pass.

Build the executable product with the build script. The current debug regression runner imports RecorderUI with `@testable`; release-building every package target is not the application's release check. Keep tests out of the shipped bundle.

Do not run real-user destructive tests or record private audio to manufacture evidence. Generate fixtures in temporary directories. Do not upload audio or issue reports externally without the user's authorization.

## Required integrated scenarios

| Scenario | Expected result |
|---|---|
| Existing v1 completed M4A | Loads, plays, renames, exports and trims; no missing-raw assumption; original bytes preserved |
| Existing v1 interrupted/partial capture | Still recoverable with its issue; schema migration does not erase/reclassify missing sources |
| New capture -> pause -> resume -> stop | Continuous recorded-frame timeline; pause absent; normal primary export; retained raw sources |
| Pause -> long wait -> duration limit | Only captured frames consume limit; no watchdog failure while paused |
| Pause/resume transition -> quit/sleep/error | One safe cleanup/final outcome; no hidden capture or stale enabled Start button |
| Rename/favorite/tag -> async refresh/export | Metadata preserved; no stale whole-session save overwrites edits |
| Filter while playing -> clear filter | Correct audio continues; title/position do not jump to another row |
| Seek/rate/preview -> start capture | Playback/preview stops before capture; old callbacks cannot restart audio |
| Export each preset | Actual codec/container/extension match; duration/channels/rate/peak valid |
| WAV/FLAC from legacy AAC | Usable output, correctly disclosed source quality; no claim of recovered fidelity |
| Trim across source segments/pause | Selected recorded frames exactly once; independent clip starts at zero |
| Clip/cleanup -> delete parent | New recording remains independently playable and exportable |
| Default external folder missing/full | Internal recording remains saved; external delivery error/retry is distinct |
| Filename collision/race | Existing user file unchanged; new output gets a safe unique name |
| Processing/copy/commit cancellation | Sources and prior ready assets preserved; no falsely ready half-output |
| Crash after asset promotion | Pending manifest survives; recovery validates before presenting/committing output |
| Delete cancel/failure/success | No mutation on cancel; row retained on failure; complete managed folder trashed on success |
| Parent/clip delete with external copies | Only selected managed session changes; external files stay untouched |
| Corrupt/traversal/symlink metadata | Rejected and preserved for inspection; no reads/writes/deletion outside managed paths |
| Long processing/library | Bounded audio memory/handles, responsive UI, no main-thread file scan or encode |

## Failure injection seams

Provide small injectable graph/writer/capability/capacity/Trash/delivery/player adapters where needed. Exercise the real service/controller logic behind them. A FakeCapture used only by the UI cannot prove CaptureService pause/resume correctness; a stubbed exporter cannot prove format/trim/cleanup correctness.

Cover write, close, synchronize, rename, manifest save, unavailable codec, missing input, partial reads, full volume, denied destination, corrupted bookmark, and late callbacks. Assert preserved files/content hashes and correct final states, not only that an error was thrown.

The old successful-export test expected raw deletion. Change that expectation deliberately for new retained-source sessions and add an explicit legacy fixture proving old M4A-only recordings still work. Do not drop the source-corruption/cancellation tests.

## Interface matrix

Inspect screenshots and manually interact with:

- 620 x 640 minimum content area and the normal window, light/dark appearance.
- Idle, recording, pausing, paused, resuming, stopping, rendering, copying, metadata error, Trash confirmation/error, and no search results.
- Long Unicode titles, long tags, long errors, large counts, 4-hour durations, and missing asset/device names.
- Library editor, player scrubbing, trim fields/range, destination picker/pattern preview, export preset picker, and cleanup original/processed preview.
- Keyboard-only selection/actions, text typing and paste, Return/Escape sheet behavior, slider adjustment, and VoiceOver labels/focus. Space must not start playback while typing.

Buttons must reflect the actual operation state; do not show Start recording while paused or claim a save succeeded because encoding started. Error text wraps and remains reachable. Scrolling is allowed; controls must not overlap or become unreachable.

## Release and review boundaries

- Run syntax/property-list/build checks, targeted regression suites, and the unchanged C sanitizer test. Run appropriate new sanitizer checks if the RNNoise wrapper introduces native memory ownership.
- Update README, architecture, release checklist, and validation record with actual changed behavior, retained-source storage cost, format support, and cleanup dependency/licensing.
- Check the packaged app launches and uses the new resources/dependency, not an old installed copy. Do not overwrite the original FluentU prototype.
- Review the diff for unrelated changes, user paths/credentials, force unwraps on externally supplied data, swallowed failures, accidentally enabled network calls, model downloads, and real-time callback work.
- Do not reduce macOS compatibility, disable Swift 6 checking, or assert unsupported Intel/minimum-OS qualification to make a build pass.
- Public GitHub upload, CI execution, Developer ID/notarization, minimum-OS/Intel hardware checks, and long physical-device tests remain separate until actually performed. Do not claim that this feature implementation completes those earlier release gates.

Final implementation report must list the eight features, which tests actually ran, their outcomes, and remaining manual/hardware/dependency blockers. If any required portion (including speech denoising) is incomplete, say exactly which portion and why.
