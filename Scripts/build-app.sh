#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox -c release --product SystemAudioRecorder \
    --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
binary_dir="$(swift build -c release --show-bin-path)"
stage="$(mktemp -d "$PWD/.build/bundle.XXXXXX")"
app="$stage/System Audio Recorder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SystemAudioRecorder" "$app/Contents/MacOS/SystemAudioRecorder"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/SystemAudioRecorder.icns "$app/Contents/Resources/"
cp Resources/ThirdPartyNotices.txt "$app/Contents/Resources/"
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app"
else
    codesign --force --sign "$identity" --options runtime --timestamp \
        --entitlements Resources/Recorder.entitlements "$app"
fi
codesign --verify --deep --strict "$app"
mkdir -p dist
if [[ -d 'dist/System Audio Recorder.app' ]]; then
    mv 'dist/System Audio Recorder.app' "$stage/previous.app"
fi
mv "$app" 'dist/System Audio Recorder.app'
print "Built: $PWD/dist/System Audio Recorder.app"
if [[ "$identity" == "-" ]]; then
    print 'Local ad-hoc build. Public downloads require Developer ID signing and notarization.'
fi
