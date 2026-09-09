#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Builds a convenience disk image only. It does not Developer ID-sign or notarize the app.
zsh Scripts/build-app.sh

app='dist/System Audio Recorder.app'
binary="$app/Contents/MacOS/SystemAudioRecorder"
[[ -d "$app" && -f "$binary" ]] || { print -u2 'The app bundle was not built.'; exit 1; }

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
architectures=$(lipo -archs "$binary")
if [[ "$architectures" == 'arm64' ]]; then
    architecture='arm64'
elif [[ "$architectures" == 'x86_64' ]]; then
    architecture='x86_64'
elif [[ "$architectures" == *'arm64'* && "$architectures" == *'x86_64'* ]]; then
    architecture='universal'
else
    print -u2 "Unsupported release architecture: $architectures"
    exit 1
fi

output="dist/SystemAudioRecorder-${version}-${architecture}-unsigned.dmg"
checksum="$output.sha256"
if [[ -e "$output" || -e "$checksum" ]]; then
    print -u2 "Refusing to overwrite an existing release artifact: $output"
    exit 1
fi

dmg_workspace=$(mktemp -d "$PWD/.build/dmg.XXXXXX")
trap 'rm -rf "$dmg_workspace"' EXIT
image_root="$dmg_workspace/System Audio Recorder"
archive="$dmg_workspace/$(basename "$output")"
mkdir -p "$image_root"
ditto "$app" "$image_root/System Audio Recorder.app"
ln -s /Applications "$image_root/Applications"

hdiutil create -volname 'System Audio Recorder' -srcfolder "$image_root" -format UDZO -ov "$archive"
mv "$archive" "$output"
(cd dist && shasum -a 256 "$(basename "$output")" > "$(basename "$checksum")")

print "Built unsigned DMG: $PWD/$output"
print "Checksum: $PWD/$checksum"
print 'This app is not Developer ID-signed or notarized. Downloaders must use macOS Open Anyway after verifying its source.'
