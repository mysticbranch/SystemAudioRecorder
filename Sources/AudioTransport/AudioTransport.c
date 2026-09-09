#include "AudioTransport.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct RecorderTransport {
    float *samples;
    uint32_t capacity, microphone_channels, channels, system_index, microphone_index;
    _Atomic uint64_t read_position, write_position, callbacks;
    _Atomic uint32_t fault, system_peak_bits, microphone_peak_bits;
    _Atomic bool accepting;
    // The producer alone accesses timeline state.
    bool has_previous_time;
    double expected_time;
};

RecorderTransport *recorder_transport_create(uint32_t capacity, uint32_t microphone_channels,
                                            uint32_t system_index, uint32_t microphone_index) {
    if (capacity == 0 || capacity > 192000 * 8 || microphone_channels > 2 ||
        system_index > 1 || (microphone_channels && (microphone_index > 1 || microphone_index == system_index))) return NULL;
    RecorderTransport *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->capacity = capacity; t->microphone_channels = microphone_channels;
    t->channels = 2 + microphone_channels;
    t->system_index = system_index; t->microphone_index = microphone_index;
    t->samples = calloc((size_t)capacity * t->channels, sizeof(float));
    if (!t->samples) { free(t); return NULL; }
    atomic_init(&t->read_position, 0); atomic_init(&t->write_position, 0);
    atomic_init(&t->callbacks, 0); atomic_init(&t->fault, 0);
    atomic_init(&t->system_peak_bits, 0); atomic_init(&t->microphone_peak_bits, 0);
    atomic_init(&t->accepting, true);
    if (!atomic_is_lock_free(&t->write_position) || !atomic_is_lock_free(&t->fault) ||
        !atomic_is_lock_free(&t->accepting)) { recorder_transport_destroy(t); return NULL; }
    return t;
}
void recorder_transport_destroy(RecorderTransport *t) {
    if (t) { free(t->samples); free(t); }
}
void recorder_transport_stop(RecorderTransport *t) {
    if (t) atomic_store_explicit(&t->accepting, false, memory_order_release);
}
static void fail(RecorderTransport *t, uint32_t fault) {
    uint32_t expected = RecorderTransportOK;
    atomic_compare_exchange_strong_explicit(&t->fault, &expected, fault, memory_order_relaxed, memory_order_relaxed);
    recorder_transport_stop(t);
}
static void store_peak(_Atomic uint32_t *destination, float value) {
    uint32_t bits; memcpy(&bits, &value, sizeof(bits));
    atomic_store_explicit(destination, bits, memory_order_relaxed);
}
uint32_t recorder_transport_feed(RecorderTransport *t, const float *system, const float *microphone,
                                uint32_t frames, double sample_time, bool has_sample_time) {
    if (!t || !atomic_load_explicit(&t->accepting, memory_order_acquire)) return 0;
    atomic_fetch_add_explicit(&t->callbacks, 1, memory_order_relaxed);
    if (!frames) return 0;
    if (!system || (t->microphone_channels && !microphone)) { fail(t, RecorderTransportLayoutChanged); return 0; }
    if (has_sample_time) {
        if (!isfinite(sample_time) || (t->has_previous_time && fabs(sample_time - t->expected_time) > 1.0)) {
            fail(t, RecorderTransportTimelineChanged); return 0;
        }
        t->expected_time = sample_time + frames; t->has_previous_time = true;
    } else {
        t->has_previous_time = false;
    }
    const uint64_t write = atomic_load_explicit(&t->write_position, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&t->read_position, memory_order_acquire);
    if (frames > t->capacity || write - read + frames > t->capacity) {
        fail(t, RecorderTransportOverflow); return 0;
    }
    float system_peak = 0, mic_peak = 0;
    for (uint32_t frame = 0; frame < frames; frame++) {
        const size_t target = (size_t)((write + frame) % t->capacity) * t->channels;
        for (uint32_t channel = 0; channel < t->channels; channel++) {
            const float value = channel < 2 ? system[(size_t)frame * 2 + channel]
                : microphone[(size_t)frame * t->microphone_channels + channel - 2];
            if (!isfinite(value)) { fail(t, RecorderTransportInvalidSamples); return 0; }
            t->samples[target + channel] = value;
            if (channel < 2) system_peak = fmaxf(system_peak, fabsf(value));
            else mic_peak = fmaxf(mic_peak, fabsf(value));
        }
    }
    store_peak(&t->system_peak_bits, system_peak); store_peak(&t->microphone_peak_bits, mic_peak);
    atomic_store_explicit(&t->write_position, write + frames, memory_order_release);
    return frames;
}
uint32_t recorder_transport_read(RecorderTransport *t, float *destination, uint32_t maximum_frames) {
    if (!t || !destination) return 0;
    const uint64_t read = atomic_load_explicit(&t->read_position, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&t->write_position, memory_order_acquire);
    const uint32_t count = (uint32_t)((write - read) < maximum_frames ? write - read : maximum_frames);
    for (uint32_t frame = 0; frame < count; frame++) {
        memcpy(destination + (size_t)frame * t->channels,
               t->samples + (size_t)((read + frame) % t->capacity) * t->channels,
               sizeof(float) * t->channels);
    }
    atomic_store_explicit(&t->read_position, read + count, memory_order_release);
    return count;
}
RecorderTransportStats recorder_transport_stats(RecorderTransport *t) {
    RecorderTransportStats result = {0};
    if (!t) return result;
    const uint64_t read = atomic_load_explicit(&t->read_position, memory_order_acquire);
    result.accepted_frames = atomic_load_explicit(&t->write_position, memory_order_acquire);
    result.buffered_frames = result.accepted_frames >= read ? result.accepted_frames - read : 0;
    result.callbacks = atomic_load_explicit(&t->callbacks, memory_order_relaxed);
    result.fault = atomic_load_explicit(&t->fault, memory_order_relaxed);
    uint32_t bits = atomic_load_explicit(&t->system_peak_bits, memory_order_relaxed);
    memcpy(&result.system_peak, &bits, sizeof(bits));
    bits = atomic_load_explicit(&t->microphone_peak_bits, memory_order_relaxed);
    memcpy(&result.microphone_peak, &bits, sizeof(bits));
    return result;
}
OSStatus recorder_transport_attach(AudioObjectID device, RecorderTransport *transport, AudioDeviceIOProcID *io_proc) {
    return AudioDeviceCreateIOProcID(device, recorder_audio_callback, transport, io_proc);
}
OSStatus recorder_audio_callback(AudioObjectID device, const AudioTimeStamp *now,
                                const AudioBufferList *input, const AudioTimeStamp *input_time,
                                AudioBufferList *output, const AudioTimeStamp *output_time, void *context) {
    (void)device; (void)now; (void)output; (void)output_time;
    RecorderTransport *t = context;
    if (!t || !atomic_load_explicit(&t->accepting, memory_order_acquire)) return noErr;
    const uint32_t expected_count = t->microphone_channels ? 2 : 1;
    if (!input || input->mNumberBuffers != expected_count || t->system_index >= expected_count) {
        fail(t, RecorderTransportLayoutChanged); return noErr;
    }
    const AudioBuffer system = input->mBuffers[t->system_index];
    if (system.mNumberChannels != 2 || system.mDataByteSize % (2 * sizeof(float))) {
        fail(t, RecorderTransportLayoutChanged); return noErr;
    }
    const uint32_t frames = system.mDataByteSize / (2 * sizeof(float));
    const float *microphone = NULL;
    if (t->microphone_channels) {
        const AudioBuffer mic = input->mBuffers[t->microphone_index];
        if (mic.mNumberChannels != t->microphone_channels ||
            mic.mDataByteSize != (uint64_t)frames * t->microphone_channels * sizeof(float)) {
            fail(t, RecorderTransportLayoutChanged); return noErr;
        }
        microphone = mic.mData;
    }
    recorder_transport_feed(t, system.mData, microphone, frames,
                            input_time ? input_time->mSampleTime : 0,
                            input_time && (input_time->mFlags & kAudioTimeStampSampleTimeValid));
    return noErr;
}
