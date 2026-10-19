import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite struct ReverseProtocolTests {
    @Test func randomFragmentationPreservesAllFrameBoundaries() throws {
        let frames = try (0..<120).map { index -> ReverseFrame in
            switch index % 3 {
            case 0: return try .json(["type": "input", "action": "text", "text": "中文输入 · 第\(index)帧 👋"])
            case 1: return .init(kind: .video, timestamp: UInt64(index * 16667), keyFrame: index % 7 == 0,
                                 payload: Data((0..<(index * 13)).map { UInt8($0 % 256) }))
            default: return .init(kind: .audio, timestamp: UInt64(index), payload: Data(repeating: 42, count: index * 3))
            }
        }
        let stream = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        // Fixed reproducible seeds exercise one-byte headers and coalesced frames.
        for seed in 1...25 {
            var state = UInt64(seed), offset = 0, parser = ReverseFrameParser(), decoded: [ReverseFrame] = []
            while offset < stream.count {
                state = state &* 6364136223846793005 &+ 1
                let end = min(offset + Int(state % 511) + 1, stream.count)
                decoded += try parser.append(stream.subdata(in: offset..<end)); offset = end
            }
            #expect(decoded == frames)
            #expect(!parser.hasPartialFrame)
        }
    }

    @Test func coalescedFramesAndResetDiscardOldConnectionBytes() throws {
        let first = try ReverseFrame.json(["type": "ping"]), second = try ReverseFrame.json(["type": "pong"])
        var parser = ReverseFrameParser()
        let partial = try parser.append(first.encoded().prefix(7))
        #expect(partial.isEmpty); #expect(parser.hasPartialFrame)
        parser.reset()
        let all = try parser.append(second.encoded() + first.encoded())
        #expect(all == [second, first]); #expect(!parser.hasPartialFrame)
    }

    @Test func rejectsOversizedAndMalformedHeadersBeforeReceivingBodies() throws {
        for length in [0, 9, ReverseFrame.maximumBody + 1, Int(UInt32.max)] {
            var parser = ReverseFrameParser()
            #expect(throws: ReverseProtocolError.invalidLength) { try parser.append(header(length)) }
        }
        var jsonParser = ReverseFrameParser()
        #expect(throws: ReverseProtocolError.invalidLength) {
            try jsonParser.append(header(65536 + 11) + Data([ReverseFrame.Kind.json.rawValue]))
        }
        var unknownParser = ReverseFrameParser()
        #expect(throws: ReverseProtocolError.invalidKind) { try unknownParser.append(header(1000) + Data([255])) }
        var flagParser = ReverseFrameParser()
        #expect(throws: ReverseProtocolError.invalidKind) {
            try flagParser.append(header(1000) + Data([2]) + Data(repeating: 0, count: 8) + Data([2]))
        }
    }

    @Test func exactPayloadLimitsAndTimestampAreRoundTripped() throws {
        let frame = ReverseFrame(kind: .video, timestamp: UInt64(Int64.max), keyFrame: true,
                                 payload: Data(repeating: 9, count: ReverseFrame.maximumBody - 10))
        var parser = ReverseFrameParser()
        let decoded = try parser.append(frame.encoded())
        #expect(decoded == [frame])
        let tooLarge = ReverseFrame(kind: .audio, payload: Data(count: ReverseFrame.maximumBody - 9))
        #expect(throws: ReverseProtocolError.invalidLength) { try tooLarge.encoded() }
        let tooLargeJSON = ReverseFrame(kind: .json, payload: Data(count: 65537))
        #expect(throws: ReverseProtocolError.invalidLength) { try tooLargeJSON.encoded() }
        let limitJSON = ReverseFrame(kind: .json, payload: Data(count: 65536))
        #expect(try limitJSON.encoded().count == 65550)
    }

    @Test func jsonMustBeUTF8DictionaryWithTypeAndSafeValues() throws {
        let invalid = [Data("[]".utf8), Data("{\"type\":false}".utf8), Data("not json".utf8),
                       Data([0xff, 0xfe, 0xfd]), "{\"type\":\"ping\"}".data(using: .utf16)!,
                       "{\"type\":\"ping\"}".data(using: .utf16LittleEndian)!]
        for payload in invalid {
            #expect(throws: ReverseProtocolError.invalidJSON) { try ReverseFrame(kind: .json, payload: payload).object() }
        }
        #expect(throws: ReverseProtocolError.invalidJSON) { try ReverseFrame.json(["type": "bad", "value": Double.infinity]) }
        let text = "汉字、🙂、e\u{301}"
        let object = try ReverseFrame.json(["type": "input", "text": text]).object()
        #expect(object["text"] as? String == text)
    }

    @Test func helloRejectsUnknownVersionsAndJSONBooleanNumericBridging() throws {
        var hello: [String: Any] = ["type": "hello", "protocolVersion": 1, "deviceID": UUID().uuidString, "channel": "control"]
        try ReverseValidation.validateHello(hello)
        for version: Any in [0, 2, 1.5, true, "1", NSNull()] {
            hello["protocolVersion"] = version
            let received = try ReverseFrame.json(hello).object()
            #expect(throws: ReverseProtocolError.unsupportedVersion) { try ReverseValidation.validateHello(received) }
        }
        hello["protocolVersion"] = 1; hello["channel"] = "other"
        #expect(throws: ReverseProtocolError.invalidJSON) { try ReverseValidation.validateHello(hello) }
        hello["channel"] = "media"; hello["deviceID"] = "not-a-uuid"
        #expect(throws: ReverseProtocolError.invalidJSON) { try ReverseValidation.validateHello(hello) }
    }

    @Test func normalizedCoordinatesAndScrollingRejectNonNumericOrUnboundedValues() throws {
        for action in ["move", "down", "up", "click", "doubleClick", "rightClick"] {
            #expect(ReverseValidation.validateInput(["type": "input", "action": action, "x": 0, "y": 1]))
            for value: Any in [-0.01, 1.01, Double.nan, Double.infinity, true, "0.5", NSNull()] {
                #expect(!ReverseValidation.validateInput(["type": "input", "action": action, "x": value, "y": 0.5]))
            }
        }
        #expect(ReverseValidation.validateInput(["type": "input", "action": "scroll", "dx": -1000, "dy": 1000]))
        for value: Any in [1001, Double.nan, true, "1"] {
            #expect(!ReverseValidation.validateInput(["type": "input", "action": "scroll", "dx": value, "dy": 0]))
        }
        let bridged = try ReverseFrame.json(["type": "input", "action": "click", "x": true, "y": false]).object()
        #expect(!ReverseValidation.validateInput(bridged))
    }

    @Test func textLimitsUseUTF8BytesAndKeyAllowList() {
        #expect(ReverseValidation.validateInput(["type": "input", "action": "text", "text": String(repeating: "中", count: 1365) + "a"]))
        for text in ["", "a\u{0}b", String(repeating: "中", count: 1366)] {
            #expect(!ReverseValidation.validateInput(["type": "input", "action": "text", "text": text]))
        }
        #expect(ReverseValidation.validateInput(["type": "input", "action": "key", "key": "copy"]))
        #expect(ReverseValidation.validateInput(["type": "input", "action": "key", "key": "delete"]))
        #expect(!ReverseValidation.validateInput(["type": "input", "action": "key", "key": "shutdown"]))
        #expect(!ReverseValidation.validateInput(["type": "input", "action": "shell", "text": "hello"]))
        #expect(!ReverseValidation.validateInput(["type": "other", "action": "key", "key": "enter"]))
    }

    @Test func sessionIsolationAndRetryBudgetRequireActualRenderedFrame() {
        var gate = ReverseSessionGate()
        #expect(!gate.accepts(0))
        let initial = gate.begin()
        for expected in [1, 2, 4] { let delay = gate.nextRetryDelay(); #expect(delay == expected) }
        let exhausted = gate.nextRetryDelay(); #expect(exhausted == nil)
        #expect(gate.accepts(initial)) // Transport epochs independently isolate each reconnect.
        gate.renderedFrame()
        let afterFrame = gate.nextRetryDelay(); #expect(afterFrame == 1)
        gate.end(); #expect(!gate.accepts(initial))
        let stopped = gate.nextRetryDelay(); #expect(stopped == nil)
        let next = gate.begin(); #expect(next != initial); #expect(!gate.accepts(initial)); #expect(gate.accepts(next))
        #expect(gate.retryCount == 0)
    }

    @Test func secretComparisonRejectsEmptyMismatchAndDifferentUTF8Lengths() {
        #expect(ReverseValidation.equalSecret("测试-abc", "测试-abc"))
        for pair in [("", ""), ("abc", "abd"), ("a", "aa"), ("é", "e\u{301}")] {
            #expect(!ReverseValidation.equalSecret(pair.0, pair.1))
        }
    }

    private func header(_ length: Int) -> Data {
        var value = UInt32(length).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
