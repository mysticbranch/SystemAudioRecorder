#include "RecorderDenoise.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>

static void *check_channel(void *unused) {
    (void)unused;
    assert(recorder_denoise_frame_size() == 480);
    RecorderDenoiseState *signal = recorder_denoise_create();
    RecorderDenoiseState *silence = recorder_denoise_create();
    assert(signal && silence);
    float input[480], zero[480] = {0}, output[480], quiet[480];
    for (int block = 0; block < 200; ++block) {
        for (int i = 0; i < 480; ++i) input[i] = 3000 * sinf((float)(block * 480 + i) * 0.0576f);
        recorder_denoise_process(signal, output, input);
        recorder_denoise_process(silence, quiet, zero);
        for (int i = 0; i < 480; ++i) {
            assert(isfinite(output[i]) && isfinite(quiet[i]));
            assert(fabsf(quiet[i]) < 0.001f); // Independent state cannot leak another channel.
        }
    }
    recorder_denoise_destroy(signal); recorder_denoise_destroy(silence);
    return NULL;
}
int main(void) {
    pthread_t workers[4];
    for (int i = 0; i < 4; ++i) assert(pthread_create(&workers[i], NULL, check_channel, NULL) == 0);
    for (int i = 0; i < 4; ++i) assert(pthread_join(workers[i], NULL) == 0);
    puts("RNNoise concurrent initialization, independent states, finite output: PASS");
    return 0;
}
