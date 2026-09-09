#ifndef RECORDER_AUDIO_TRANSPORT_H
#define RECORDER_AUDIO_TRANSPORT_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct RecorderTransport RecorderTransport;
enum RecorderTransportFault {
    RecorderTransportOK = 0,
    RecorderTransportOverflow = 1,
    RecorderTransportLayoutChanged = 2,
    RecorderTransportTimelineChanged = 3,
    RecorderTransportInvalidSamples = 4
};
typedef struct {
    uint64_t callbacks;
    uint64_t accepted_frames;
    uint64_t buffered_frames;
    uint32_t fault;
    float system_peak;
    float microphone_peak;
} RecorderTransportStats;

RecorderTransport *recorder_transport_create(uint32_t capacity, uint32_t microphone_channels,
                                            uint32_t system_index, uint32_t microphone_index);
// Only destroy after the audio IOProc has been successfully detached.
void recorder_transport_destroy(RecorderTransport *transport);
void recorder_transport_stop(RecorderTransport *transport);
uint32_t recorder_transport_feed(RecorderTransport *transport, const float *system,
                                const float *microphone, uint32_t frames,
                                double sample_time, bool has_sample_time);
uint32_t recorder_transport_read(RecorderTransport *transport, float *destination, uint32_t maximum_frames);
RecorderTransportStats recorder_transport_stats(RecorderTransport *transport);
OSStatus recorder_transport_attach(AudioObjectID device, RecorderTransport *transport, AudioDeviceIOProcID *io_proc);
OSStatus recorder_audio_callback(AudioObjectID device, const AudioTimeStamp *now,
                                const AudioBufferList *input, const AudioTimeStamp *input_time,
                                AudioBufferList *output, const AudioTimeStamp *output_time, void *context);
#endif
