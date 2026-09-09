import AudioToolbox
import Foundation
import RecorderCore

func audioCheck(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw RecorderFailure("\(operation) failed (audio error \(status)). Your source audio has been kept.")
    }
}

/// Synchronous, explicitly finalized file I/O for background queues only.
protocol CaptureWriting: AnyObject {
    var writtenFrames: Int64 { get }
    func write(_ samples: UnsafePointer<Float>, frames: UInt32) throws
    func close() throws
}

final class AudioFileWriter: CaptureWriting {
    private var file: ExtAudioFileRef?
    private let url: URL
    let channels: UInt32
    private(set) var writtenFrames: Int64 = 0

    convenience init(url: URL, sampleRate: Double, channels: UInt32, compressed: Bool) throws {
        try self.init(url: url, sampleRate: sampleRate, channels: channels, preset: compressed ? .balanced : nil)
    }
    init(url: URL, sampleRate: Double, channels: UInt32, preset: ExportPreset? = nil, outputSampleRate: Double? = nil) throws {
        self.channels = channels
        self.url = url
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var destination = client
        destination.mSampleRate = outputSampleRate ?? sampleRate
        if let preset {
            guard channels == 2 else { throw RecorderFailure("Exports require two channels.") }
            destination = AudioStreamBasicDescription()
            destination.mSampleRate = 48_000; destination.mChannelsPerFrame = 2
            destination.mFormatID = preset.formatID
            if preset == .wav {
                destination.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                destination.mBitsPerChannel = 24; destination.mBytesPerFrame = 6
                destination.mBytesPerPacket = 6; destination.mFramesPerPacket = 1
            } else {
                if preset == .appleLossless { destination.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData }
                if preset == .flac { destination.mBitsPerChannel = 24 }
                var size = UInt32(MemoryLayout.size(ofValue: destination))
                try audioCheck(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destination), "Configuring the output codec")
            }
        }
        try audioCheck(ExtAudioFileCreateWithURL(url as CFURL, preset?.fileType ?? kAudioFileCAFType,
                                                &destination, nil, 0, &file), "Creating the audio file")
        do {
            guard let file else { throw RecorderFailure("macOS did not create the audio file.") }
            try audioCheck(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout.size(ofValue: client)), &client), "Setting the audio format")
            if let bitrate = preset?.bitrate {
                var converter: AudioConverterRef?
                var size = UInt32(MemoryLayout.size(ofValue: converter))
                try audioCheck(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter), "Preparing AAC encoding")
                if let converter {
                    var bitrate = bitrate
                    try audioCheck(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                                               UInt32(MemoryLayout.size(ofValue: bitrate)), &bitrate), "Setting AAC quality")
                }
            }
        } catch {
            if let file { ExtAudioFileDispose(file) }; file = nil
            throw error
        }
    }
    func write(_ samples: UnsafePointer<Float>, frames: UInt32) throws {
        guard let file else { throw RecorderFailure("The audio file is already closed.") }
        var buffers = AudioBufferList(mNumberBuffers: 1,
                                      mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: frames * channels * 4,
                                                            mData: UnsafeMutableRawPointer(mutating: samples)))
        try audioCheck(ExtAudioFileWrite(file, frames, &buffers), "Writing audio")
        writtenFrames += Int64(frames)
    }
    func close() throws {
        guard let current = file else { return }
        file = nil
        try audioCheck(ExtAudioFileDispose(current), "Finalizing the audio file")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    deinit { if let file { ExtAudioFileDispose(file) } }
}

extension ExportPreset {
    var formatID: AudioFormatID {
        switch codec { case .aac: kAudioFormatMPEG4AAC; case .alac: kAudioFormatAppleLossless; case .pcm: kAudioFormatLinearPCM; case .flac: kAudioFormatFLAC }
    }
    var fileType: AudioFileTypeID {
        switch container { case .m4a: kAudioFileM4AType; case .wav: kAudioFileWAVEType; case .flac: kAudioFileFLACType }
    }
}
