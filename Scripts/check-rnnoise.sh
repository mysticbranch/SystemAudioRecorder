#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 - <<'PY'
from pathlib import Path
import hashlib, json
root = Path('Vendor/RNNoise')
for name, expected in json.loads((root / 'LOCAL-SHA256.json').read_text()).items():
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit('RNNoise source checksum mismatch: ' + name)
print('Pinned RNNoise source and model checksums: PASS')
PY
mkdir -p .build/rnnoise-checks
clang -std=c11 -g -O1 -fsanitize=address,undefined -DRNNOISE_BUILD \
    -I Vendor/RNNoise/include -I Vendor/RNNoise/src \
    Vendor/RNNoise/RecorderDenoise.c Vendor/RNNoise/src/{denoise,rnn,rnn_data,pitch,kiss_fft,celt_lpc}.c \
    Tests/RNNoiseChecks.c -pthread -o .build/rnnoise-checks/check
.build/rnnoise-checks/check
