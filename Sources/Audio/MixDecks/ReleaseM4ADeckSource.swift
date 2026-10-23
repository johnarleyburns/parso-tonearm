#if !os(watchOS)
import AudioToolbox
import Foundation

/// A deck's decoded-audio supplier: seekable, bounded, cancellable. Starter Blends only ever use
/// range-backed implementations of this; there is no resident-PCM implementation.
protocol StarterDeckSource: DeckChunkSource, AnyObject {
    var sampleRate: Double { get }
    var totalFrames: Int64 { get }
    /// Aborts any read in flight; later reads throw `ReleaseRangeError.cancelled`.
    func cancel()
}

private let releaseReadProc: AudioFile_ReadProc = { clientData, position, requestCount, buffer, actualCount in
    Unmanaged<ReleaseM4ADeckSource>.fromOpaque(clientData).takeUnretainedValue()
        .supply(position: position, count: requestCount, into: buffer, actual: actualCount)
}

private let releaseSizeProc: AudioFile_GetSizeProc = { clientData in
    Unmanaged<ReleaseM4ADeckSource>.fromOpaque(clientData).takeUnretainedValue().assetLength
}

/// Decodes a release M4A straight from byte ranges: CoreAudio's `AudioFile` pulls only the bytes it
/// needs (the `moov` index, then the frames around the seek target) through `ReleaseRangeReader`,
/// and `ExtAudioFile` decodes them to float PCM on demand. Nothing is written to disk and no more
/// than the reader's bounded chunk cache plus one decode chunk is ever resident.
final class ReleaseM4ADeckSource: StarterDeckSource, @unchecked Sendable {
    private let reader: ReleaseRangeReader
    private let lock = NSLock()
    private var audioFile: AudioFileID?
    private var ext: ExtAudioFileRef?
    private var position: Int64 = 0
    private var failure: ReleaseRangeError?
    private(set) var sampleRate: Double = 0
    private(set) var totalFrames: Int64 = 0
    let channelCount = 2
    fileprivate var assetLength: Int64 = 0

    /// Opens the asset (blocking: reads the container index). Throws `ReleaseRangeError`.
    /// `fileType` is the container hint: M4A for Starter assets, MP3 for Jamendo streams.
    init(reader: ReleaseRangeReader, fileType: AudioFileTypeID = kAudioFileM4AType) throws {
        self.reader = reader
        assetLength = try reader.totalLength()
        let me = Unmanaged.passUnretained(self).toOpaque()
        var fileID: AudioFileID?
        let opened = AudioFileOpenWithCallbacks(me, releaseReadProc, nil, releaseSizeProc, nil,
                                                fileType, &fileID)
        guard opened == noErr, let fileID else { throw failure ?? .permanent("not an M4A (\(opened))") }
        audioFile = fileID
        var wrapped: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(fileID, false, &wrapped) == noErr, let wrapped else {
            AudioFileClose(fileID)
            throw failure ?? .permanent("cannot decode")
        }
        ext = wrapped
        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var length: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat) == noErr,
              ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length) == noErr,
              fileFormat.mSampleRate > 0, length > 0 else {
            dispose()
            throw failure ?? .permanent("no audio")
        }
        // Decode at the file's own rate: seek positions and plan seconds stay in one frame unit.
        var client = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
        guard ExtAudioFileSetProperty(wrapped, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
            dispose()
            throw failure ?? .permanent("unsupported format")
        }
        sampleRate = fileFormat.mSampleRate
        totalFrames = length
    }

    deinit { dispose() }

    private func dispose() {
        if let ext { ExtAudioFileDispose(ext) }
        if let audioFile { AudioFileClose(audioFile) }
        ext = nil
        audioFile = nil
    }

    fileprivate func supply(position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer,
                            actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        do {
            let data = try reader.read(offset: position, count: Int(count))
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
            actual.pointee = UInt32(data.count)
            return data.count < Int(count) ? kAudioFileEndOfFileError : noErr
        } catch {
            failure = (error as? ReleaseRangeError) ?? .transient(error.localizedDescription)
            actual.pointee = 0
            return kAudioFileUnspecifiedError
        }
    }

    func cancel() { reader.cancel() }

    func read(startFrame: Int64, count: Int) throws -> [[Float]] {
        try lock.withLock {
            guard let ext else { throw ReleaseRangeError.cancelled }
            let start = min(max(0, startFrame), totalFrames)
            let wanted = Int(max(0, min(Int64(count), totalFrames - start)))
            guard wanted > 0 else { return [[], []] }
            failure = nil
            if start != position {
                guard ExtAudioFileSeek(ext, start) == noErr else {
                    throw failure ?? ReleaseRangeError.permanent("seek failed")
                }
                position = start
            }
            var leftPlane = [Float](repeating: 0, count: wanted)
            var rightPlane = [Float](repeating: 0, count: wanted)
            var frames = UInt32(wanted)
            let status: OSStatus = leftPlane.withUnsafeMutableBufferPointer { left in
                rightPlane.withUnsafeMutableBufferPointer { right in
                    let list = AudioBufferList.allocate(maximumBuffers: channelCount)
                    defer { free(list.unsafeMutablePointer) }
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(wanted * 4), mData: left.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(wanted * 4), mData: right.baseAddress)
                    return ExtAudioFileRead(ext, &frames, list.unsafeMutablePointer)
                }
            }
            guard status == noErr else {
                position = -1                                  // force a re-seek after any error
                throw failure ?? ReleaseRangeError.permanent("decode failed (\(status))")
            }
            let delivered = Int(frames)
            position = start + Int64(delivered)
            return delivered < wanted ? [Array(leftPlane.prefix(delivered)), Array(rightPlane.prefix(delivered))]
                                      : [leftPlane, rightPlane]
        }
    }
}
#endif
