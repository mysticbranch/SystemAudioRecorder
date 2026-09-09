# Contributing

Keep recording safety changes separate from new features where practical. Read [the architecture](docs/architecture.md) before changing capture or export.

1. Describe the user-visible problem and expected outcome.
2. Add or adjust a regression check that exercises the failure, not just implementation details.
3. Run `zsh Scripts/check.sh` and `zsh Scripts/build-app.sh`.
4. For UI changes, inspect minimum-size, normal-size, light, and dark states, including errors and recovery.
5. For audio changes, include the relevant hardware checks from [the release checklist](docs/release-checklist.md).

No allocations, locks, file I/O, logging, Swift object work, or UI calls belong in the audio callback. Never delete recovery sources before a validated export is persisted. Never downgrade an interrupted capture to a complete recording to make an error disappear.

Do not commit recordings, transcripts, credentials, signing certificates, `.build`, or `dist`. Keep signing credentials in Keychain or protected CI secrets. Avoid personal absolute paths in code and documentation.

Pull requests should describe behavior, validation performed, and remaining hardware or OS limitations. CI success does not replace real device testing.
