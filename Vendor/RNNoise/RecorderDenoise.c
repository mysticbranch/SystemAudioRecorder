#include "RecorderDenoise.h"
#include "rnnoise.h"
#include <pthread.h>
#include <stdlib.h>
extern int recorder_rnnoise_prepare(void);
extern int recorder_rnnoise_frame_size(void);
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int ready = 0;
static void prepare(void) { ready = recorder_rnnoise_prepare(); }
int recorder_denoise_frame_size(void) { return recorder_rnnoise_frame_size(); }
RecorderDenoiseState *recorder_denoise_create(void) {
    if (pthread_once(&once, prepare) != 0 || !ready) return NULL;
    DenoiseState *state = calloc(1, (size_t)rnnoise_get_size());
    if (!state) return NULL;
    if (rnnoise_init(state) != 0) { free(state); return NULL; }
    return state;
}
void recorder_denoise_destroy(RecorderDenoiseState *state) { rnnoise_destroy(state); }
void recorder_denoise_process(RecorderDenoiseState *state, float *output, const float *input) {
    (void)rnnoise_process_frame(state, output, input);
}
