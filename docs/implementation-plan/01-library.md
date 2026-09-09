# Task 1 — Rename, search, tags, favorites, and sorting

Depends on [shared contracts](00-shared-contracts.md). Keep the existing local session store; no database or network search.

## User behavior

- Show the recording title as the main row label, with date, duration, source, and saved/partial/recovery status underneath.
- Add an Edit details sheet with Title, Tags, Save, and Cancel. Double-clicking a title may open it, but an explicit accessible button/menu action must also exist.
- Add a favorite toggle per row and an All/Favorites filter.
- Add a search field and sorting choices: Newest first (default), Oldest first, Title A–Z, Longest first.
- Add tag filtering using existing tags; clicking a tag filters the list. Multiple selected tags require all selected tags (AND).
- Display `N of M recordings`, distinguish an empty library from no search matches, and provide Clear filters.
- Show retained-source and total managed storage size in details. Calculate sizes asynchronously; do not traverse folders during every SwiftUI body evaluation.
- Add a refresh action; refresh on app activation to detect files restored through Finder. Never run crash-recovery rewriting as part of an ordinary refresh during capture.

## Rules to implement

Title editing: trim leading/trailing whitespace, reject empty/newline/control-character values, maximum 120 user-perceived characters for a new edit. Preserve previously valid legacy titles up to the existing 500-character validation limit; do not truncate on migration. New untitled recordings should get a useful date-based default. Renaming never moves a UUID folder or changes exported-file paths.

Tags: at most 10 per recording, at most 24 characters each, trimmed, nonempty, no newline/control characters. Dedupe case/diacritic-insensitively while preserving the first display spelling. Empty comma-separated input means no tags; document commas as separators rather than supporting quoted nested syntax.

Search: trim and split the query on whitespace. Every term must occur somewhere in the combined title and tags, using case- and diacritic-insensitive matching. Do not search audio/transcripts, internal paths, or arbitrary filesystem contents. Combine search, tags, and Favorites with AND. Sort ties deterministically by creation time and UUID.

Selection: use UUID, not array position. Filtering an item out clears its detail selection; it does not delete the item. Search alone must not stop playback; the player retains an explicit playing ID/title even when that row is hidden. Deletion and actual file disappearance do stop playback. A late library refresh cannot re-select a previously deleted or filtered-out item.

## Implementation map

- Extend `RecordingSession.swift` and the migration from task 0.
- Add `LibraryQuery.swift` in RecorderCore for pure filtering/sorting/normalization rules.
- Add `LibraryModel.swift` in RecorderUI for loaded sessions, query/filter/sort state, selection reconciliation, and async refresh generation.
- Add SessionStore metadata-update methods which reload the latest manifest under the lock and update only title/tags/favorite. Preserve assets, capture status, and recovery issues.
- Extract `RecordingListView`, `RecordingRowView`, and `RecordingDetailsSheet` from ContentView as needed. RecorderModel remains the command coordinator; do not maintain two independent session lists.
- Run list/metadata/size I/O on a background serial executor. Keep draft text in the sheet until Save succeeds. Use a loading indicator and a non-destructive error if persistence fails; a failed Save does not close/discard the draft.
- Apply the shared operation guards before Save/favorite changes. Disable mutation while capturing, paused, or another file operation is reserved. Query/filter changes remain available.

## Acceptance tests

1. Load v1 title/status/audio paths unchanged; add tags/favorite and relaunch successfully.
2. Rename changes the title only. A Unicode title and original audio hashes survive round-trip persistence.
3. Cancel edit leaves the manifest unchanged. Empty, too-long, and control-character values show inline validation.
4. Inject write failure: original metadata remains valid, draft stays visible, no optimistic permanent favorite/title state.
5. Search `uber meeting` matches title `Über` plus tag `Meeting`; every term is required. Tag/favorite filters combine correctly.
6. Sorting has stable results for equal dates/titles/durations. Legacy missing duration is handled without a crash.
7. Filtered-out playback continues with its correct title; clearing filters does not change which audio is playing.
8. Out-of-order refresh responses cannot restore stale search results or a removed selection.
9. Generate at least 1,000 metadata fixtures; search/sort stays responsive and does not decode audio or scan file sizes per keystroke. Do not load all audio samples into memory.
10. Check minimum window size, long Unicode titles/tags, no-results state, VoiceOver labels, and keyboard access to Edit/Save/Cancel.

Deliver this task with migration/query/persistence tests and a screenshot of the library and details sheet. Do not implement Smart Folders, full-text transcription search, or external folder indexing.
