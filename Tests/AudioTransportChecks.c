#include "AudioTransport.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>

enum { capacity = 1024, block = 64, total = block * 20000 };

static void *produce(void *context) {
    RecorderTransport *transport = context;
    float system[block * 2], microphone[block];
    for (unsigned position = 0; position < total; position += block) {
        while (recorder_transport_stats(transport).buffered_frames > capacity - block) sched_yield();
        for (unsigned frame = 0; frame < block; frame++) {
            system[frame * 2] = (float)(position + frame);
            system[frame * 2 + 1] = -(float)(position + frame);
            microphone[frame] = (float)((position + frame) % 100);
        }
        assert(recorder_transport_feed(transport, system, microphone, block, position, true) == block);
    }
    return NULL;
}

int main(void) {
    RecorderTransport *transport = recorder_transport_create(capacity, 1, 1, 0);
    assert(transport);
    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce, transport) == 0);
    float samples[127 * 3];
    unsigned position = 0;
    while (position < total) {
        unsigned count = recorder_transport_read(transport, samples, 127);
        if (!count) { sched_yield(); continue; }
        for (unsigned frame = 0; frame < count; frame++) {
            assert(samples[frame * 3] == (float)(position + frame));
            assert(samples[frame * 3 + 1] == -(float)(position + frame));
            assert(samples[frame * 3 + 2] == (float)((position + frame) % 100));
        }
        position += count;
    }
    assert(pthread_join(producer, NULL) == 0);
    assert(recorder_transport_stats(transport).fault == 0);
    recorder_transport_stop(transport);
    recorder_transport_destroy(transport);

    transport = recorder_transport_create(8, 0, 0, 0);
    assert(transport);
    AudioBufferList invalid = { .mNumberBuffers = 1, .mBuffers = {{ .mNumberChannels = 1 }} };
    assert(recorder_audio_callback(0, NULL, &invalid, NULL, NULL, NULL, transport) == noErr);
    assert(recorder_transport_stats(transport).fault == RecorderTransportLayoutChanged);
    recorder_transport_destroy(transport);
    puts("PASS Concurrent transport: 1,280,000 frames, stereo/microphone ordering, wraparound, malformed callback");
    return 0;
}
