import AudioTransport
import CoreAudio
import Foundation
import RecorderCore

/// All operations except the C callback execute on CaptureService's serial queue.
protocol CaptureGraphControlling: AnyObject {
    var transport: OpaquePointer? { get }
    var sampleRate: Double { get }
    var microphoneChannels: Int { get }
    var microphoneUID: String? { get }
    func start() throws
    func checkConfiguration() throws
    func detach() throws
    func close() throws
}

final class CaptureGraph: CaptureGraphControlling {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private(set) var transport: OpaquePointer?
    private(set) var sampleRate: Double = 0
    private(set) var microphoneChannels: Int = 0
    private var microphone: MicrophoneDevice?
    var microphoneUID: String? { microphone?.uid }
    private var started = false
    private var originalFormats: [AudioStreamBasicDescription] = []
    private var originalStreamIDs: [AudioObjectID] = []
    private var originalChannels: [UInt32] = []

    init(includeMicrophone: Bool, microphoneID: UInt32?) throws {
        do {
            try configure(includeMicrophone: includeMicrophone, microphoneID: microphoneID)
        } catch {
            try? close()
            throw error
        }
    }
    private func configure(includeMicrophone: Bool, microphoneID: UInt32?) throws {
        if includeMicrophone { microphone = try AudioDevices.microphone(id: microphoneID) }
        try createTap()
        try createDevice()
        try configureFormat(includeMicrophone: includeMicrophone)
        try createTransport()
    }
    private func createTap() throws {
        var pid = getpid(), processID: AudioObjectID = 0
        var size = UInt32(MemoryLayout.size(ofValue: processID))
        var property = AudioProperties.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                                UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &processID)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: status == noErr && processID != 0 ? [processID] : [])
        description.name = "System Audio Recorder"
        description.isPrivate = true; description.muteBehavior = .unmuted
        var createdTap: AudioObjectID = 0
        try audioCheck(AudioHardwareCreateProcessTap(description, &createdTap), "Requesting system audio access")
        tap = createdTap
    }
    private func createDevice() throws {
        let tapUID = try AudioProperties.string(tap, kAudioTapPropertyUID)
        var configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "System Audio Recorder Input",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let microphone {
            configuration[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: microphone.uid]]
            configuration[kAudioAggregateDeviceMainSubDeviceKey] = microphone.uid
        }
        var createdDevice: AudioObjectID = 0
        try audioCheck(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &createdDevice), "Preparing audio capture")
        device = createdDevice
    }
    private func configureFormat(includeMicrophone: Bool) throws {
        let expectedStreams = includeMicrophone ? 2 : 1
        var streamIDs: [AudioObjectID] = []
        // The HAL publishes new aggregate streams asynchronously; this is never the UI thread.
        for _ in 0..<100 {
            streamIDs = (try? AudioProperties.ids(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)) ?? []
            if streamIDs.count >= expectedStreams { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard streamIDs.count == expectedStreams else {
            throw RecorderFailure("This device layout is not supported yet. Use a standard mono/stereo microphone or system audio only.")
        }
        originalStreamIDs = streamIDs
        originalFormats = try streamIDs.map { try AudioProperties.scalar($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) }
        originalChannels = try AudioProperties.bufferChannels(device)
        guard originalChannels.count == expectedStreams else { throw RecorderFailure("The audio device uses an unsupported buffer layout.") }
        for (index, format) in originalFormats.enumerated() {
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  format.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0,
                  format.mChannelsPerFrame == originalChannels[index],
                  format.mBytesPerFrame == format.mChannelsPerFrame * 4 else {
                throw RecorderFailure("This audio format is not supported. Select another microphone or record system audio only.")
            }
        }
        // Supported aggregate layout: one physical input stream followed by the stereo tap.
        // Reject other layouts rather than silently assigning them to the wrong source.
        guard originalChannels.last == 2 else { throw RecorderFailure("The system audio tap did not provide stereo audio.") }
        microphoneChannels = includeMicrophone ? Int(originalChannels[0]) : 0
        guard microphoneChannels <= 2 else { throw RecorderFailure("Select a mono or stereo microphone.") }
        sampleRate = try AudioProperties.scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              abs(sampleRate - originalFormats[0].mSampleRate) < 1 else {
            throw RecorderFailure("The input devices do not share a supported audio clock.")
        }
    }
    private func createTransport() throws {
        let expectedStreams = microphone == nil ? 1 : 2
        guard let ring = recorder_transport_create(UInt32(sampleRate * 4), UInt32(microphoneChannels),
                                                   UInt32(expectedStreams - 1), 0) else {
            throw RecorderFailure("There is not enough memory for a safe recording buffer.")
        }
        transport = ring
        var createdIO: AudioDeviceIOProcID?
        // Keep the C function pointer bridge in C; Swift 6.3's region analysis
        // crashes when passing this imported callback directly from Swift.
        try audioCheck(recorder_transport_attach(device, ring, &createdIO), "Preparing the audio callback")
        io = createdIO
    }
    func start() throws {
        guard let io else { throw RecorderFailure("The audio input is not ready.") }
        try audioCheck(AudioDeviceStart(device, io), "Starting audio capture")
        started = true
    }
    func checkConfiguration() throws {
        let alive = try AudioProperties.scalar(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
        guard alive != 0 else { throw RecorderFailure("The recording device disconnected.") }
        if let microphone {
            guard try AudioProperties.scalar(microphone.id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0 else {
                throw RecorderFailure("The microphone disconnected. The available recording has been kept.")
            }
        }
        let rate = try AudioProperties.scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        let streams = try AudioProperties.ids(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        let channels = try AudioProperties.bufferChannels(device)
        guard abs(rate - sampleRate) < 1, streams == originalStreamIDs, channels == originalChannels else {
            throw RecorderFailure("The audio device configuration changed. Start a new recording after choosing your devices.")
        }
        for (index, stream) in streams.enumerated() {
            let format = try AudioProperties.scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            let original = originalFormats[index]
            guard format.mSampleRate == original.mSampleRate, format.mFormatID == original.mFormatID,
                  format.mFormatFlags == original.mFormatFlags, format.mChannelsPerFrame == original.mChannelsPerFrame,
                  format.mBytesPerFrame == original.mBytesPerFrame else {
                throw RecorderFailure("The audio format changed during recording. The available audio has been kept.")
            }
        }
    }
    func detach() throws {
        if let transport { recorder_transport_stop(transport) }
        var stopError: OSStatus = noErr
        if started, let io { stopError = AudioDeviceStop(device, io); started = false }
        if let io {
            let result = AudioDeviceDestroyIOProcID(device, io)
            // On failure retain callback context; CaptureService prevents further starts.
            try audioCheck(result, "Detaching the audio callback")
            self.io = nil
        }
        try audioCheck(stopError, "Stopping the audio device")
    }
    func close() throws {
        try detach()
        if let transport { recorder_transport_destroy(transport); self.transport = nil }
        if device != 0 {
            try audioCheck(AudioHardwareDestroyAggregateDevice(device), "Removing the private audio device")
            device = 0
        }
        if tap != 0 {
            try audioCheck(AudioHardwareDestroyProcessTap(tap), "Removing the audio tap")
            tap = 0
        }
    }
    deinit {
        // If detachment fails, intentionally leave the C context allocated until process exit.
        // Leaking one bounded buffer is preferable to freeing memory still used by Core Audio.
        try? close()
    }
}
