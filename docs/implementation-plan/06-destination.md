# Task 6 — Preferred export folder and filename pattern

Depends on format-aware assets. The preferred destination receives copies; the internal session store remains the authoritative recovery library.

## Behavior and settings

- Settings: Save exported copies automatically (off initially), Choose folder…, displayed folder path, filename pattern, live filename preview, and Reset to default.
- Default pattern: `{date}_{time}_{title}`. Extension is appended from the actual output format; it is not part of the pattern.
- Supported tokens only: `{date}` = YYYY-MM-DD, `{time}` = HH-mm-ss, `{title}`, `{id}` = full session UUID. Use POSIX/Gregorian formatting; snapshot local timezone when building the immutable delivery request. No custom expressions/date-format strings.
- The date/time is the recording's createdAt, not the moment a retry happens. Snapshot the fully expanded name per delivery job so preferences/timezone/title changes cannot rename an in-flight retry unexpectedly.
- Show a name preview for the chosen format before saving settings/exporting. Unknown tokens, unmatched braces, or an empty literal/template are inline errors.
- Automatically copy a successfully committed primary recording/clip/cleaned copy when enabled. Additional Export… requests can use the preferred folder or a one-off chosen destination.
- Keep existing Save a copy… for an explicit NSSavePanel destination and overwrite confirmation. Make it format-aware; do not silently change its file extension.

## Storage and bookmark implementation

Add `ExportDestinationStore` to persist preferences/bookmark data separately from session metadata. Add `ExportDeliveryService` for resolved destination checks and copying. AppKit folder selection is on MainActor; resolution/I/O/copy work is off it.

Use NSOpenPanel configured for a single directory. Store URL bookmark data rather than relying only on a path. Resolve on each job; refresh a stale bookmark when access still succeeds. A missing/disconnected folder produces Choose another folder / Retry, not automatic recreation somewhere else.

The current app is not App Sandbox enabled. Use bookmark/access options compatible with that build. If a sandboxed variant is later used, security-scoped access must be acquired for the whole background operation and released on every success/error/cancellation path. Do not make `startAccessingSecurityScopedResource() == false` a universal failure for an ordinary accessible nonsandbox URL.

Reject a preferred destination that is the managed Sessions root or inside it. Otherwise a supposedly external copy might be deleted with a session. Resolve path ancestry correctly; do not use a string-prefix comparison that mistakes sibling names for descendants. A chosen destination can be a cloud-synced/external folder; explain that other software controls its subsequent syncing.

## Naming and copy algorithm

1. Expand known tokens as data, never through a shell. Preserve Unicode letters. Replace path separators, colon, and control characters with `-`; trim leading/trailing dots/spaces. Treat `.`/`..` as invalid results. Collapse repeated replacement separators for readability.
2. Limit the base to 180 UTF-8 bytes without splitting a Unicode scalar/grapheme; append a bounded collision suffix and correct extension. If sanitization makes it empty, use `Recording-<UUID>`.
3. Automatic delivery never overwrites. Try base.ext, base-2.ext, base-3.ext, etc. Use an atomic no-clobber publish operation, such as the platform's exclusive rename, and retry name collisions. A check-then-overwriting-rename is not sufficient. If the volume cannot support the chosen safe operation, fail safely with an actionable error rather than overwriting.
4. Copy to a unique sibling temporary file on the destination volume, check bytes/size (and streaming hash if needed), synchronize/close it, then publish. Clean only the temporary file owned by this job on failure. Never delete/modify a pre-existing destination file to reserve a name.
5. Explicit Save Panel replacement requires the system's overwrite confirmation and uses a synchronized sibling temporary file plus checked replacement. Preserve the old destination if copying fails. Self-copy resolves to a safe no-op with a clear result.
6. Record pending/succeeded/failed external delivery separately from internal session status. If destination copy fails, say “Recording saved in the app; external copy failed.” Keep Retry and Show internal file actions. Do not call the recording interrupted or erase its primary asset.
7. Retry must not rerender audio unnecessarily or blindly create duplicate external files. Give a delivery request its own UUID and persisted target/size/hash outcome; if an already-published result matches, adopt/report it, otherwise select a new collision-safe name. A crash after publish but before bookkeeping must preserve the file, not overwrite it.

Use copy buffers with cancellation checks for large files if the current synchronous FileManager copy cannot provide responsive cancellation. Quitting must wait for a bounded safe cleanup/commit path; do not quit midway through replacing a confirmed user destination.

## Tests

- Folder selection cancelled: settings and files unchanged.
- Bookmark resolves after folder move; stale bookmark refresh succeeds; missing drive/revoked access reports failure and leaves internal audio ready.
- Unknown token, malformed braces, slash/colon/control characters, all-invalid names, Unicode, very long titles, and DST/timezone changes produce documented names or errors.
- Same name exists, simultaneous competing creation occurs, or filesystem is case-insensitive: no overwrite; correct suffix chosen safely.
- Disk full, failed sync, interrupted copy, and failed replacement preserve original destination and internal recording.
- Source and destination are the same file (including a resolved symlink): no destructive operation.
- Failure after internal commit does not rerender/reclassify the recording. Retry copies the same asset and avoids duplicates after a simulated crash.
- WAV/FLAC/ALAC destinations get the right extension/content type, never hard-coded `.m4a`.
- Selecting a folder inside the managed store is rejected. External copies remain after session Trash.
- Manual GUI test: choose an ordinary folder, a removable volume, and a Save Panel overwrite/cancel flow with generated audio only.

Reference: [Foundation URL bookmarks](https://developer.apple.com/documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:)), [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel). Check exact SDK signatures before coding.
