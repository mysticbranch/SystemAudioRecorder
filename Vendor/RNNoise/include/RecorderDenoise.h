#ifndef RECORDER_DENOISE_H
#define RECORDER_DENOISE_H
typedef struct DenoiseState RecorderDenoiseState;
int recorder_denoise_frame_size(void);
RecorderDenoiseState *recorder_denoise_create(void);
void recorder_denoise_destroy(RecorderDenoiseState *state);
void recorder_denoise_process(RecorderDenoiseState *state, float *output, const float *input);
#endif
