import Foundation
import AudioToolbox
import CoreMedia
import Testing
@testable import MacDisplayCapture

@Suite("AAC packet conversion")
struct AACEncoderTests {
    @Test(arguments: [false, true]) func convertsChunkedPCMToRawAAC(planar: Bool) throws {
        var configuration: [String: Any]?
        var audioPackets: [(Data, UInt64)] = []
        let encoder = try AACEncoder { packet in
            switch packet {
            case .configuration(let value): configuration = value
            case .audio(let data, let pts): audioPackets.append((data, pts))
            default: break
            }
        }
        for offset in stride(from: 0, to: 48_000, by: 480) {
            try encoder.append(makePCM(frames: 480, offset: offset, planar: planar))
        }
        #expect(configuration?["codec"] as? String == "aac")
        #expect(configuration?["csd"] as? String == Data([0x11, 0x90]).base64EncodedString())
        #expect(audioPackets.count >= 40)
        #expect(audioPackets.allSatisfy { !$0.0.isEmpty && $0.0.count < 4096 })
        for index in 1..<audioPackets.count {
            #expect(audioPackets[index].1 > audioPackets[index - 1].1)
            #expect((21333...21334).contains(audioPackets[index].1 - audioPackets[index - 1].1))
        }
    }

    private func makePCM(frames: Int, offset: Int, planar: Bool) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0), mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1,
            mBytesPerFrame: planar ? 4 : 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &block) == noErr)
        let samples = (0..<(frames * 2)).map { Float(sin(Double(offset + (planar ? $0 % frames : $0 / 2)) * 2 * .pi * 440 / 48_000) * 0.1) }
        samples.withUnsafeBytes { data in
            #expect(CMBlockBufferReplaceDataBytes(with: data.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = planar ? 4 : 8
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!,
            formatDescription: format!, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
