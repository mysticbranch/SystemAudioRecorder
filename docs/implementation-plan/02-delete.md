# Task 2 — Delete recording through Trash

Depends on [shared contracts](00-shared-contracts.md) and [library identity/selection](01-library.md).

## Exact behavior

The action is labeled **Move to Trash…**. It removes one managed session, including its internal exports, retained CAF sources, metadata, and internal pending-job files. It never deletes any external Save Copy/automatic-export files. The user can restore the session folder through Finder; an in-app Undo system and permanent deletion are not required.

Offer this action on saved, partial, interrupted, and inactive failed/preparing sessions that belong to the library. Do not allow it for the current active or paused capture, any in-use render/preview, or while another mutation is running. Unreadable unknown folders get Show in Finder, not a guessed recursive delete.

Confirmation sheet:

> Move “<title>” to Trash?
>
> This moves this recording, its source audio, and its internal exports to Trash. Separate clips and copies saved outside the app stay where they are.

Independent derived clip/cleaned-copy sessions are separate recordings and are **not** included in the parent's deletion. Internal format exports belonging to that session are included.

Buttons: Cancel (default safe action) and Move to Trash (destructive role). Show estimated managed size if already available, otherwise omit it rather than blocking the sheet.

## Implementation steps

1. Reserve the file-operation state before presenting confirmation; record the exact session UUID. Cancel releases the reservation with no filesystem change.
2. On confirm, recheck capture/job ownership and re-resolve the session by UUID. Never resolve via row index or current search position.
3. Stop/release playback and previews for this session. Under the conservative shared policy, do not start a competing playback/render while deletion runs.
4. Validate that the target is exactly a direct UUID child of SessionStore.root, with matching metadata identity. Reject redirected/symlinked paths; never accept an arbitrary path from a title or caller.
5. Call Foundation `FileManager.trashItem(at:resultingItemURL:)` on a background executor. Wrap it behind an injectable `TrashService` so most tests do not touch the real user's Trash.
6. Do not substitute `removeItem`, `rm`, or permanent recursive deletion if Trash is unavailable/full/unwritable. Display the error and preserve the list entry.
7. Remove the row/reconcile selection only after successful Trash completion. Clear caches keyed by the session ID only after success; removing generated preview cache files is allowed, never external copies.
8. If the directory was already removed externally, refresh and report that it is no longer available; do not claim that this invocation moved it to Trash.
9. When a UUID folder is restored to the managed root, refresh can rediscover it. Folder/manifest ID mismatch is reported as unreadable, never “repaired” by overwriting another session.

Suggested files: `Sources/RecorderCore/SessionStore.swift`, new `TrashService.swift` (Foundation only), library/model command coordination, row action/confirmation sheet. Keep AppKit presentation on MainActor and disk work off it.

## Acceptance tests

- Cancel: injected Trash service called zero times; metadata and audio hashes unchanged.
- Success: correct UUID directory passed exactly once; session sources and exports move together; row disappears.
- Failure: row remains, selection remains usable, error visible, no permanent-delete fallback.
- Double click/Return repetition: one Trash operation only.
- Playback: old player is released before filesystem mutation; late completion callback cannot resurrect the deleted player.
- Active/paused/pausing/resuming/exporting/copying session: command rejected even if invoked directly, not only disabled in UI.
- A similarly named session and an external copy remain unchanged.
- Parent deletion leaves an independent derived clip playable. Clip deletion leaves parent playable.
- Symlink/traversal/mismatched-identity requests are rejected.
- Separate explicitly documented manual integration test moves a generated fixture to the real macOS Trash and restores it. Do not use real user recordings for destructive tests.

Reference: [Foundation Trash API](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)). Verify the exact Swift signature in the installed SDK before implementation.
