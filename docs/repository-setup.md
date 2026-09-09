# GitHub repository setup

This file is the post-push setup checklist for `mysticbranch/SystemAudioRecorder`. It covers GitHub configuration, while [release-checklist.md](release-checklist.md) covers the macOS application and distribution gates.

## Already in the repository

- `LICENSE` selects MIT for the application code. GitHub recognizes it after the first push. Vendored RNNoise keeps its own BSD-style license and notices; it is not relicensed as MIT.
- `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue forms, CI, and Dependabot configuration are versioned here.
- CI runs regression checks, native sanitizers, and an unsigned app build on macOS. It uploads the unsigned local app only as a seven-day workflow artifact.

## Configure in GitHub after the first push

1. Open the repository **About** settings. Keep the description `A native macOS system-audio recorder`; add topics: `macos`, `swift`, `swiftui`, `audio`, `system-audio`, `audio-recording`, and `coreaudio`.
2. Confirm GitHub displays the MIT license. Keep the third-party notice link in the README because RNNoise is under different terms.
3. In **Settings → Security**, enable private vulnerability reporting. Verify that the security issue-form link works before advertising releases.
4. Decide whether **Projects** and **Wiki** are useful. For a small issue-driven project, disabling both reduces unused public surfaces. Issues should remain enabled.
5. In **Actions → General**, set the workflow token to read-only and allow only required actions. The committed workflow already requests `contents: read`.
6. After the first green Actions run, protect `main`: require the `Build and verify` check for pull requests and block force pushes/deletions. If the maintainer needs direct hotfixes, decide that explicitly rather than leaving the branch unintentionally open.
7. Add a repository social preview image only after confirming the current app icon has publishable provenance. Do not use the carried-over prototype icon until then.

## Before a public binary release

1. Complete every applicable manual item in [release-checklist.md](release-checklist.md), especially physical capture, audio listening, accessibility, and clean-machine installation.
2. Obtain a Developer ID Application certificate and create a `notarytool` Keychain profile locally or in protected CI secrets. Never commit certificates, profiles, or Apple credentials.
3. Build, notarize, staple, and assess the exact archive using `Scripts/release.sh`. Attach only that verified archive and its SHA-256 to a GitHub Release.
4. Create a release tag such as `v0.2.0`, write user-facing release notes, and mark it as a pre-release until the qualification checklist is complete.
5. Enable GitHub’s release notes generation if useful. Do not enable automatic binary publishing until signing/notarization and the release process have been rehearsed.

## Optional, after the project has contributors

- Add a Discussions category for support and ideas if Issues become too noisy.
- Add a funding file only when there is a real destination to publish.
- Add a `CODEOWNERS` file and required reviews if multiple maintainers take ownership.
- Add an Intel macOS runner or external hardware validation only after deciding which macOS versions and CPU architectures the project supports.
