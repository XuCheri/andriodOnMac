import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import VideoToolbox

public struct CaptureDisplay: Identifiable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public let bounds: CGRect
    public init(id: UInt32, name: String, width: Int, height: Int, bounds: CGRect) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.bounds = bounds
    }
}

public enum MediaPacket {
    case configuration([String: Any])
    case video(Data, pts: UInt64, keyFrame: Bool)
    case audio(Data, pts: UInt64)
}

public enum MacCaptureError: LocalizedError {
    case permission, displayUnavailable, encoder(OSStatus), audio(String)
    public var errorDescription: String? {
        switch self {
        case .permission: return "请在系统设置中允许 AndroidOnMac 录制屏幕，然后重新开始共享。"
        case .displayUnavailable: return "所选显示器已断开，请重新选择。"
        case .encoder(let status): return "无法启动硬件视频编码器（\(status)）。"
        case .audio(let message): return "系统声音采集不可用：\(message)"
        }
    }
}

private final class EncodedFrameContext {
    let generation: UUID
    init(_ generation: UUID) { self.generation = generation }
}

/// The packet callback must enqueue promptly; it must not wait for a network write.
/// All capture and codec state is owned by `queue`. Call start/stop sequentially.
public final class MacCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "chat.xucheri.AndroidOnMac.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var audioEncoder: AACEncoder?
    private var generation: UUID?
    private var lifecycleID = UUID()
    private var packet: ((MediaPacket) -> Void)?
    private var errorHandler: ((String) -> Void)?
    private var forceKeyFrame = true
    private var configSent = false
    private var pendingFrames = 0
    private var currentBitrate = 8_000_000
    private var outputWidth = 0
    private var outputHeight = 0
    private var audioFailed = false
    private var lastImage: CVPixelBuffer?
    private var lastEncodedPTS = CMTime.invalid

    public override init() { super.init() }
    public static var screenCaptureAllowed: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenCapture() { CGRequestScreenCaptureAccess() }

    public static func displays() async throws -> [CaptureDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let names = await MainActor.run {
            Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
                return (id, screen.localizedName)
            })
        }
        return content.displays.map {
            CaptureDisplay(id: $0.displayID, name: names[$0.displayID] ?? "显示器 \($0.displayID)",
                           width: $0.width, height: $0.height, bounds: CGDisplayBounds($0.displayID))
        }.sorted { $0.id == CGMainDisplayID() || ($1.id != CGMainDisplayID() && $0.id < $1.id) }
    }

    public func start(displayID: UInt32, maxDimension: Int, fps: Int, bitrate: Int, audio: Bool,
                      onPacket: @escaping (MediaPacket) -> Void, onError: @escaping (String) -> Void) async throws {
        await stop()
        let attempt = await withCheckedContinuation { (continuation: CheckedContinuation<UUID, Never>) in
            queue.async { self.lifecycleID = UUID(); continuation.resume(returning: self.lifecycleID) }
        }
        guard Self.screenCaptureAllowed else { throw MacCaptureError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw MacCaptureError.displayUnavailable }
        let limit = min(3840, max(640, maxDimension))
        let scale = min(1, Double(limit) / Double(max(display.width, display.height)))
        let width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        let frameRate = min(60, max(10, fps))
        let selectedBitrate = min(40_000_000, max(500_000, bitrate))
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = audio
        config.sampleRate = 48_000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.lifecycleID == attempt else { throw CancellationError() }
                    self.generation = UUID()
                    self.packet = onPacket; self.errorHandler = onError
                    self.outputWidth = width; self.outputHeight = height
                    self.currentBitrate = selectedBitrate
                    self.forceKeyFrame = true; self.configSent = false; self.pendingFrames = 0; self.audioFailed = false
                    try self.createEncoder(width: width, height: height, fps: frameRate, bitrate: selectedBitrate)
                    if audio { self.audioEncoder = try AACEncoder(onPacket: onPacket) }
                    self.stream = newStream
                    continuation.resume()
                } catch {
                    if self.lifecycleID == attempt { self.clearCodecs() }
                    continuation.resume(throwing: error)
                }
            }
        }
        do {
            try await newStream.startCapture()
            let current = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                queue.async { continuation.resume(returning: self.lifecycleID == attempt && self.stream === newStream) }
            }
            guard current, !Task.isCancelled else {
                try? await newStream.stopCapture()
                throw CancellationError()
            }
        } catch {
            // A superseded start must never tear down a newer sharing session.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    if self.lifecycleID == attempt { self.stream = nil; self.clearCodecs() }
                    continuation.resume()
                }
            }
            try? await newStream.stopCapture()
            throw error
        }
    }

    public func stop() async {
        let (old, stoppedID) = await withCheckedContinuation { (continuation: CheckedContinuation<(SCStream?, UUID), Never>) in
            queue.async {
                let old = self.stream
                self.lifecycleID = UUID()
                self.stream = nil; self.generation = nil
                continuation.resume(returning: (old, self.lifecycleID))
            }
        }
        if let old { try? await old.stopCapture() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.lifecycleID == stoppedID { self.clearCodecs() }
                continuation.resume()
            }
        }
    }

    public func requestKeyFrame() {
        queue.async {
            self.forceKeyFrame = true
            // ScreenCaptureKit emits idle samples on a static desktop. Reuse the
            // latest retained image so decoder recovery does not need a mouse move.
            if let image = self.lastImage, let generation = self.generation, self.pendingFrames < 3 {
                self.encode(image, pts: CMClockGetTime(CMClockGetHostTimeClock()), generation: generation)
            }
        }
    }
    public func reduceBitrate() {
        queue.async {
            guard let encoder = self.encoder else { return }
            self.currentBitrate = max(500_000, self.currentBitrate * 3 / 4)
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: self.currentBitrate as CFNumber)
            self.forceKeyFrame = true
        }
    }

    private func clearCodecs() {
        generation = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil; audioEncoder = nil; packet = nil; errorHandler = nil
        pendingFrames = 0; lastImage = nil; lastEncodedPTS = .invalid
    }

    private func createEncoder(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { refcon, frameRefcon, status, _, sample in
                guard let frameRefcon else { return }
                let context = Unmanaged<EncodedFrameContext>.fromOpaque(frameRefcon).takeRetainedValue()
                guard let refcon else { return }
                let engine = Unmanaged<MacCaptureEngine>.fromOpaque(refcon).takeUnretainedValue()
                engine.queue.async { engine.encoded(sample, status: status, generation: context.generation) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)
        guard result == noErr, let encoder else { throw MacCaptureError.encoder(result) }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(encoder, key: key, value: value)
            guard status == noErr else { throw MacCaptureError.encoder(status) }
        }
        let status = VTCompressionSessionPrepareToEncodeFrames(encoder)
        guard status == noErr else { throw MacCaptureError.encoder(status) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard self.stream === stream, let generation, sampleBuffer.isValid else { return }
        if outputType == .audio {
            guard !audioFailed, let audioEncoder else { return }
            do { try audioEncoder.append(sampleBuffer) }
            catch {
                audioFailed = true; self.audioEncoder = nil
                errorHandler?("系统声音传输已停止：\(error.localizedDescription)。视频仍在共享。")
            }
            return
        }
        guard outputType == .screen,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        lastImage = image
        encode(image, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), generation: generation)
    }

    private func encode(_ image: CVPixelBuffer, pts: CMTime, generation: UUID) {
        guard pendingFrames < 3, let encoder else { return }
        let timestamp = lastEncodedPTS.isNumeric && CMTimeCompare(pts, lastEncodedPTS) <= 0
            ? CMTimeAdd(lastEncodedPTS, CMTime(value: 1, timescale: 1_000_000)) : pts
        let properties = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyFrame = false
        let context = Unmanaged.passRetained(EncodedFrameContext(generation))
        pendingFrames += 1
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
            presentationTimeStamp: timestamp, duration: .invalid,
            frameProperties: properties, sourceFrameRefcon: context.toOpaque(), infoFlagsOut: nil)
        if result != noErr {
            context.release(); pendingFrames -= 1; forceKeyFrame = true
            errorHandler?(MacCaptureError.encoder(result).localizedDescription)
        } else { lastEncodedPTS = timestamp }
    }

    private func encoded(_ sample: CMSampleBuffer?, status: OSStatus, generation: UUID) {
        guard self.generation == generation else { return }
        pendingFrames = max(0, pendingFrames - 1)
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
            forceKeyFrame = true
            if status != noErr { errorHandler?(MacCaptureError.encoder(status).localizedDescription) }
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let keyFrame = (attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
        var nalLength: Int32 = 4
        var parameterCount = 0
        var spsPointer: UnsafePointer<UInt8>?, ppsPointer: UnsafePointer<UInt8>?
        var spsSize = 0, ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &nalLength) == noErr,
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let spsPointer, let ppsPointer, nalLength > 0, nalLength <= 4 else { forceKeyFrame = true; return }
        let startCode = Data([0, 0, 0, 1])
        let sps = startCode + Data(bytes: spsPointer, count: spsSize)
        let pps = startCode + Data(bytes: ppsPointer, count: ppsSize)
        if !configSent {
            packet?(.configuration(["type": "videoConfig", "codec": "h264", "width": outputWidth, "height": outputHeight,
                                   "csd0": sps.base64EncodedString(), "csd1": pps.base64EncodedString()]))
            configSent = true
        }
        let size = CMBlockBufferGetDataLength(block)
        guard size > 0, size <= 8_388_598 else { forceKeyFrame = true; return }
        var source = Data(count: size)
        let copyStatus = source.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copyStatus == noErr else { forceKeyFrame = true; return }
        var annexB = keyFrame ? sps + pps : Data()
        var offset = 0
        while offset + Int(nalLength) <= source.count {
            var size = 0
            for index in 0..<Int(nalLength) { size = (size << 8) | Int(source[offset + index]) }
            offset += Int(nalLength)
            guard size > 0, size <= source.count - offset else { forceKeyFrame = true; return }
            annexB.append(startCode); annexB.append(source[offset..<(offset + size)]); offset += size
        }
        guard offset == source.count, !annexB.isEmpty, let pts = Self.microseconds(CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
        packet?(.video(annexB, pts: pts, keyFrame: keyFrame))
        if forceKeyFrame, let image = lastImage {
            encode(image, pts: CMClockGetTime(CMClockGetHostTimeClock()), generation: generation)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream else { return }
            self.errorHandler?("屏幕共享已停止：\(error.localizedDescription)")
            self.stream = nil; self.clearCodecs()
        }
    }

    static func microseconds(_ time: CMTime) -> UInt64? {
        guard time.isNumeric else { return nil }
        let value = CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
        return value >= 0 ? UInt64(value) : nil
    }
}
