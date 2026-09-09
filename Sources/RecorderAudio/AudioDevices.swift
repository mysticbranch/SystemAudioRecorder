import CoreAudio
import Foundation
import RecorderCore

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    let uid: String
}

enum AudioProperties {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var value = initial, address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        try audioCheck(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Reading the audio device")
        return value
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        var address = address(selector), size = UInt32(MemoryLayout.size(ofValue: value))
        try audioCheck(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Reading the audio device name")
        guard let value else { throw RecorderFailure("The audio device returned an empty identifier.") }
        return value.takeRetainedValue() as String
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = address(selector, scope: scope), size: UInt32 = 0
        try audioCheck(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Listing audio devices")
        guard size % 4 == 0, size < 1_000_000 else { throw RecorderFailure("The audio device list is invalid.") }
        if size == 0 { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        try audioCheck(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &values), "Reading audio devices")
        return Array(values.prefix(Int(size) / 4))
    }
    static func bufferChannels(_ id: AudioObjectID) throws -> [UInt32] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        try audioCheck(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Reading the audio buffer layout")
        guard size >= MemoryLayout<AudioBufferList>.size, size < 1_000_000 else {
            throw RecorderFailure("This device has no supported audio input buffers.")
        }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        try audioCheck(AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer), "Reading the audio buffer layout")
        let list = pointer.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard count <= (Int(size) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride + 1 else {
            throw RecorderFailure("The audio buffer layout is invalid.")
        }
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }
}

public enum AudioDevices {
    public static func microphones() throws -> [MicrophoneDevice] {
        try AudioProperties.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard let channels = try? AudioProperties.bufferChannels(id), channels.reduce(0, +) > 0 else { return nil }
            return MicrophoneDevice(id: id, name: try AudioProperties.string(id, kAudioObjectPropertyName),
                                    uid: try AudioProperties.string(id, kAudioDevicePropertyDeviceUID))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func microphone(id: UInt32?) throws -> MicrophoneDevice {
        let selected = try id ?? AudioProperties.scalar(AudioObjectID(kAudioObjectSystemObject),
                                                       kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0))
        guard let device = try microphones().first(where: { $0.id == selected }) else {
            throw RecorderFailure("The selected microphone is unavailable. Choose another microphone or record system audio only.")
        }
        return device
    }
}
