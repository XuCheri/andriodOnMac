import Foundation
import AudioToolbox
import CoreMedia

/// ScreenCaptureKit is configured for 48 kHz stereo. AAC-LC packets are raw
/// access units; the AudioSpecificConfig is sent separately, with no ADTS header.
final class AACEncoder {
    private var converter: AudioConverterRef?
    private var pcm = [Float]()
    private var consumed = 0
    private var inputPointer: UnsafePointer<Float>?
    private var inputCount = 0
    private var originPTS: UInt64?
    private var outputFrames: UInt64 = 0
    private var configurationSent = false
    private let onPacket: (MediaPacket) -> Void
    private var maximumPacketSize: UInt32 = 4096
    private let needsInput: OSStatus = -19831

    init(onPacket: @escaping (MediaPacket) -> Void) throws {
        self.onPacket = onPacket
        var source = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var destination = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let status = AudioConverterNew(&source, &destination, &converter)
        guard status == noErr, let converter else { throw MacCaptureError.audio("AAC 编码器无法启动（\(status)）") }
        var bitrate: UInt32 = 128_000
        let bitrateStatus = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout.size(ofValue: bitrate)), &bitrate)
        guard bitrateStatus == noErr else { throw MacCaptureError.audio("AAC 码率设置失败（\(bitrateStatus)）") }
        var size = UInt32(MemoryLayout<UInt32>.size)
        let sizeStatus = AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maximumPacketSize)
        guard sizeStatus == noErr, maximumPacketSize > 0, maximumPacketSize <= 65536 else {
            throw MacCaptureError.audio("AAC 编码器返回了无效的帧大小")
        }
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    func append(_ sample: CMSampleBuffer) throws {
        guard let converter, let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48_000,
              asbd.mChannelsPerFrame == 2, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw MacCaptureError.audio("系统返回了不支持的 PCM 音频格式")
        }
        var required = 0
        var block: CMBlockBuffer?
        let firstStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &required,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &block)
        guard firstStatus == noErr, required > 0, required <= 4096 else { throw MacCaptureError.audio("无法读取音频缓冲区") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: required, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: required, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &block)
        guard status == noErr else { throw MacCaptureError.audio("无法读取音频样本（\(status)）") }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 48000 else { return }
        if originPTS == nil { originPTS = MacCaptureEngine.microseconds(CMSampleBufferGetPresentationTimeStamp(sample)) }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if planar {
            guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData,
                  buffers[0].mDataByteSize >= frames * 4, buffers[1].mDataByteSize >= frames * 4 else {
                throw MacCaptureError.audio("双声道音频缓冲区不完整")
            }
            let l = left.assumingMemoryBound(to: Float.self), r = right.assumingMemoryBound(to: Float.self)
            pcm.reserveCapacity(pcm.count + frames * 2)
            for index in 0..<frames { pcm.append(l[index]); pcm.append(r[index]) }
        } else {
            guard buffers.count == 1, let data = buffers[0].mData, buffers[0].mDataByteSize >= frames * 8 else {
                throw MacCaptureError.audio("交错音频缓冲区不完整")
            }
            pcm.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * 2))
        }
        guard pcm.count <= 48_000 * 2 else { throw MacCaptureError.audio("音频编码跟不上采集速度") }
        while pcm.count >= 2048 {
            consumed = 0
            var output = Data(count: Int(maximumPacketSize))
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            var outputSize = 0
            let result: OSStatus = output.withUnsafeMutableBytes { bytes in
                var outputList = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: maximumPacketSize, mData: bytes.baseAddress))
                return pcm.withUnsafeBufferPointer { input in
                    inputPointer = input.baseAddress; inputCount = input.count
                    defer { inputPointer = nil; inputCount = 0 }
                    let result = AudioConverterFillComplexBuffer(converter, { _, packetCount, ioData, packetDescriptions, userData in
                    guard let userData else { return kAudio_ParamError }
                    let owner = Unmanaged<AACEncoder>.fromOpaque(userData).takeUnretainedValue()
                    let available = (owner.inputCount - owner.consumed) / 2
                    guard available > 0, let source = owner.inputPointer else { packetCount.pointee = 0; return owner.needsInput }
                    let count = min(available, Int(packetCount.pointee))
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(count * 8),
                        mData: UnsafeMutableRawPointer(mutating: source.advanced(by: owner.consumed)))
                    owner.consumed += count * 2
                    packetCount.pointee = UInt32(count)
                    packetDescriptions?.pointee = nil
                    return noErr
                    }, Unmanaged.passUnretained(self).toOpaque(), &packets, &outputList, &description)
                    if packets > 0 { outputSize = Int(outputList.mBuffers.mDataByteSize) }
                    return result
                }
            }
            output.count = outputSize
            if consumed > 0 { pcm.removeFirst(consumed) }
            guard result == noErr || result == needsInput else { throw MacCaptureError.audio("AAC 编码失败（\(result)）") }
            if packets > 0, result == noErr, !output.isEmpty, let originPTS {
                if !configurationSent {
                    onPacket(.configuration(["type": "audioConfig", "codec": "aac", "sampleRate": 48_000,
                                              "channels": 2, "csd": Data([0x11, 0x90]).base64EncodedString()]))
                    configurationSent = true
                }
                onPacket(.audio(output, pts: originPTS + outputFrames * 1_000_000 / 48_000))
                outputFrames += 1024
            }
            if consumed == 0 || result == needsInput { break }
        }
    }
}
