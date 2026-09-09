# Free unsigned releases

GitHub Releases hosts the downloadable artifacts for this project. No separate server, storage account, or Apple Developer membership is required.

## What users receive

Each unsigned release has two assets:

- `SystemAudioRecorder-<version>-arm64-unsigned.dmg`: a drag-to-Applications disk image for Apple Silicon Macs.
- `SystemAudioRecorder-<version>-arm64-unsigned.dmg.sha256`: the SHA-256 checksum for verifying that download.

The current project has only been built and tested on Apple Silicon with macOS 14.2 or later. Do not present an `arm64` build as Intel or universal.

The app is ad-hoc signed for local development; it is not Developer ID-signed or notarized. macOS will identify it as from an unidentified developer. A user who trusts the GitHub release can move it to Applications, try to open it, then select **Open Anyway** in **System Settings → Privacy & Security**. They should not bypass that protection for software from an unknown source.

Users can instead inspect the source and build the app themselves:

```sh
git clone https://github.com/mysticbranch/SystemAudioRecorder.git
cd SystemAudioRecorder
zsh Scripts/check.sh
zsh Scripts/build-app.sh
open 'dist/System Audio Recorder.app'
```

## Create an artifact

From a clean checkout of the release commit:

```sh
zsh Scripts/check.sh
zsh Scripts/check-transport.sh
zsh Scripts/check-rnnoise.sh
zsh Scripts/build-dmg.sh
```

`Scripts/build-dmg.sh` rebuilds the app, determines its actual Mach-O architecture, creates a DMG with an Applications shortcut, and refuses to overwrite an existing artifact. It writes the DMG and checksum under `dist/`.

Open the DMG locally and test the exact packaged app before uploading it. Record the macOS version, hardware architecture, validation run, known limitations, and checksum in the release notes.

## Publish to GitHub Releases

Copy `unsigned-release-notes-template.md` to `.release-notes.md`, replace every placeholder with the real release evidence, then use GitHub CLI authenticated as the repository owner. The following creates a **pre-release** and uploads both assets; it is a public action, so run it only after checking the files and release notes:

```sh
cp docs/unsigned-release-notes-template.md .release-notes.md
```

```sh
gh release create v0.2.0 \
  dist/SystemAudioRecorder-0.2.0-arm64-unsigned.dmg \
  dist/SystemAudioRecorder-0.2.0-arm64-unsigned.dmg.sha256 \
  --title 'System Audio Recorder 0.2.0' \
  --notes-file .release-notes.md \
  --prerelease
```

Replace `v0.2.0` and both filenames with the version in `Resources/Info.plist`. Write release notes before publishing: state that the app is free, unsigned/not notarized, Apple Silicon only, requires macOS 14.2+, and list the manual validation actually performed. Do not call the download production ready until the signed/notarized qualification path is complete.

## Later signed releases

If a Developer ID membership is added later, keep the unsigned artifacts clearly separate from notarized builds. Use `Scripts/release.sh` for the signed path and attach the resulting ZIP plus checksum. Never replace an existing released artifact with a different file.
