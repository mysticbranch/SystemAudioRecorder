# System Audio Recorder <version>

## Download status

Free unsigned development build for **Apple Silicon** Macs running **macOS 14.2 or later**.

This app is not Developer ID-signed or notarized. Download only from this GitHub Release or build from source. After verifying the checksum, macOS users must choose **Open Anyway** in **System Settings → Privacy & Security** to launch it.

## Validation performed

- Commit: `<commit>`
- Build machine: `<macOS version and hardware>`
- Automated checks: `<commands and result>`
- Manual checks: `<what was actually tested>`

## Known limits

- Live-device, accessibility, long-duration, and audio-listening qualification are incomplete unless specifically listed above.
- No Intel build is provided.
- See the repository's release checklist before treating this as a production release.

## Verify download

```sh
cd ~/Downloads
shasum -a 256 -c SystemAudioRecorder-<version>-arm64-unsigned.dmg.sha256
```
