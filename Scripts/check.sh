#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift run --disable-sandbox --cache-path "$PWD/.build/cache" \
    --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" RecorderChecks "$@"
plutil -lint Resources/Info.plist Resources/Recorder.entitlements
for script in Scripts/*.sh; do zsh -n "$script"; done
