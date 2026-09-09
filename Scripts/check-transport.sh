#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/transport-checks
clang -std=c11 -Wall -Wextra -Werror -g -O1 -fsanitize=address,undefined \
    -I Sources/AudioTransport/include Sources/AudioTransport/AudioTransport.c \
    Tests/AudioTransportChecks.c -framework CoreAudio -pthread \
    -o .build/transport-checks/check
.build/transport-checks/check
