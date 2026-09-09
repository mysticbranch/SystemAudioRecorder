# Pinned offline speech denoiser

Upstream: https://github.com/xiph/rnnoise/tree/cdf196b1e9de2f8ff1003328ebf9a4316477429d

This is the original RNNoise reference model, from the v0.1 tag at commit
`cdf196b1e9de2f8ff1003328ebf9a4316477429d`. It is intentionally pinned, not a
claim that this is the newest model. No runtime downloads, training data,
credentials, Python packages, or external service are required.

Archive: `https://codeload.github.com/xiph/rnnoise/tar.gz/cdf196b1e9de2f8ff1003328ebf9a4316477429d`

Archive SHA-256: `a6f3bd89c5c12546d049bcdcf6d1b58c301fd9c811e760f3087b036a93501d98`

Bundled model (`src/rnn_data.c`) SHA-256:
`f0cdb52b30501aab489f90fedbc7a023c719d91b337db2da7f26fc3036556b95`

The curated source is the six C compilation units listed in upstream
`Makefile.am`, their headers, `include/rnnoise.h`, and the original example
for amplitude/frame conventions. COPYING and AUTHORS are retained.
`UPSTREAM-SHA256.json` records the original extracted files.
`LOCAL-SHA256.json` records every compiled source/header plus retained licenses.
Run `zsh Scripts/check-rnnoise.sh` to verify the local pin and execute native
address/undefined-behavior sanitizer checks.

Local changes:

- `RecorderDenoise.c` and its header provide typed, allocation-checked state
  creation and serialize shared FFT table initialization using `pthread_once`.
- `denoise.c` exposes checked initialization and the actual frame-size macro
  (480 samples at 48 kHz), avoiding a duplicate Swift constant.
- `kiss_fft.c` checks twiddle allocation before use and initializes ownership
  before allocation-failure cleanup.
- `rnn.c` replaces two deliberate null-pointer traps for impossible activation
  types with explicit traps, removing undefined behavior warnings.
- `module.modulemap` exports only the application wrapper to Swift.

The model and other processing code are unchanged. Models are never fetched
during builds. To audit a source update, extract the pinned archive separately,
compare it to UPSTREAM-SHA256.json, review all local patches, rerun the native
checks and audio regressions, and regenerate local checksums only after review.

The upstream BSD-style license and all leading per-file notices are also
included in `Resources/ThirdPartyNotices.txt` and copied into the app bundle.
No endorsement by upstream authors is implied. Listening evaluation with varied
speech, accents, background noise, and music remains a release requirement.
