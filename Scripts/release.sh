#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${CODE_SIGN_IDENTITY:?Set a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set an existing notarytool Keychain profile}"
if [[ "$CODE_SIGN_IDENTITY" != 'Developer ID Application:'* ]]; then
    print -u2 'A Developer ID Application identity is required for public releases.'
    exit 1
fi
zsh Scripts/check.sh
zsh Scripts/check-transport.sh
zsh Scripts/check-rnnoise.sh
zsh Scripts/build-app.sh
archive="$(mktemp -d "$PWD/.build/release.XXXXXX")/SystemAudioRecorder.zip"
ditto -c -k --keepParent 'dist/System Audio Recorder.app' "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple 'dist/System Audio Recorder.app'
xcrun stapler validate 'dist/System Audio Recorder.app'
spctl --assess --type execute --verbose=2 'dist/System Audio Recorder.app'
ditto -c -k --keepParent 'dist/System Audio Recorder.app' dist/SystemAudioRecorder.zip
shasum -a 256 dist/SystemAudioRecorder.zip
