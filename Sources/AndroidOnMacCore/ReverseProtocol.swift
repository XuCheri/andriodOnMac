import Foundation
import CoreFoundation

public enum ReverseProtocolError: Error, Equatable {
    case invalidLength, invalidKind, invalidJSON, unsupportedVersion, invalidInput
}

public struct ReverseFrame: Equatable {
    public enum Kind: UInt8 { case json = 1, video = 2, audio = 3 }
    public static let maximumBody = 8 * 1024 * 1024
    public let kind: Kind
    public let timestamp: UInt64
    public let keyFrame: Bool
    public let payload: Data
    public init(kind: Kind, timestamp: UInt64 = 0, keyFrame: Bool = false, payload: Data) {
        self.kind = kind; self.timestamp = timestamp; self.keyFrame = keyFrame; self.payload = payload
    }
    public static func json(_ value: [String: Any]) throws -> Self {
        guard JSONSerialization.isValidJSONObject(value) else { throw ReverseProtocolError.invalidJSON }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 65536 else { throw ReverseProtocolError.invalidLength }
        return Self(kind: .json, payload: data)
    }
    public func object() throws -> [String: Any] {
        guard kind == .json, payload.count <= 65536,
              String(data: payload, encoding: .utf8) != nil, !payload.contains(0),
              let value = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              value["type"] is String else { throw ReverseProtocolError.invalidJSON }
        return value
    }
    public func encoded() throws -> Data {
        guard payload.count + 10 <= Self.maximumBody,
              kind != .json || payload.count <= 65536 else { throw ReverseProtocolError.invalidLength }
        var data = Data()
        var length = UInt32(payload.count + 10).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(kind.rawValue)
        var pts = timestamp.bigEndian
        withUnsafeBytes(of: &pts) { data.append(contentsOf: $0) }
        data.append(keyFrame ? 1 : 0)
        data.append(payload)
        return data
    }
}

public struct ReverseFrameParser {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ incoming: Data) throws -> [ReverseFrame] {
        guard incoming.count <= ReverseFrame.maximumBody + 4 else { throw ReverseProtocolError.invalidLength }
        buffer.append(incoming)
        var result: [ReverseFrame] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (10...ReverseFrame.maximumBody).contains(length) else { throw ReverseProtocolError.invalidLength }
            // Reject a hostile declared JSON length after five bytes, without
            // buffering an otherwise valid eight-megabyte media-sized body.
            if buffer.count >= 5 {
                guard let kind = ReverseFrame.Kind(rawValue: buffer[buffer.startIndex + 4]) else {
                    throw ReverseProtocolError.invalidKind
                }
                guard kind != .json || length - 10 <= 65536 else { throw ReverseProtocolError.invalidLength }
            }
            if buffer.count >= 14, buffer[buffer.startIndex + 13] & 0xfe != 0 {
                throw ReverseProtocolError.invalidKind
            }
            guard buffer.count >= length + 4 else { break }
            let body = Array(buffer.prefix(length + 4).dropFirst(4))
            guard let kind = ReverseFrame.Kind(rawValue: body[0]), body[9] & 0xfe == 0 else {
                throw ReverseProtocolError.invalidKind
            }
            let pts = body[1...8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let payload = Data(body.dropFirst(10))
            guard kind != .json || payload.count <= 65536 else { throw ReverseProtocolError.invalidLength }
            result.append(.init(kind: kind, timestamp: pts, keyFrame: body[9] == 1, payload: payload))
            buffer.removeFirst(length + 4)
        }
        guard buffer.count <= ReverseFrame.maximumBody + 4 else { throw ReverseProtocolError.invalidLength }
        return result
    }
    public var hasPartialFrame: Bool { !buffer.isEmpty }
    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

/// Pure session isolation shared by asynchronous sender operations and tests.
public struct ReverseSessionGate {
    public private(set) var generation: UInt64 = 0
    public private(set) var isActive = false
    public private(set) var retryCount = 0
    public init() {}
    @discardableResult public mutating func begin() -> UInt64 {
        generation &+= 1; isActive = true; retryCount = 0; return generation
    }
    public mutating func end() { generation &+= 1; isActive = false; retryCount = 0 }
    public func accepts(_ value: UInt64) -> Bool { isActive && generation == value }
    public mutating func nextRetryDelay() -> Int? {
        guard isActive, retryCount < 3 else { return nil }
        let delay = 1 << retryCount; retryCount += 1; return delay
    }
    public mutating func renderedFrame() { retryCount = 0 }
}

public enum ReverseValidation {
    public static func validateHello(_ object: [String: Any]) throws {
        guard object["type"] as? String == "hello",
              let id = object["deviceID"] as? String, UUID(uuidString: id) != nil,
              let channel = object["channel"] as? String, ["control", "media"].contains(channel)
        else { throw ReverseProtocolError.invalidJSON }
        guard integer(object["protocolVersion"]) == 1 else { throw ReverseProtocolError.unsupportedVersion }
    }
    public static func normalizedPoint(_ object: [String: Any]) -> (Double, Double)? {
        guard let x = number(object["x"]), let y = number(object["y"]),
              x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }
    public static func validateInput(_ object: [String: Any]) -> Bool {
        guard object["type"] as? String == "input", let action = object["action"] as? String else { return false }
        switch action {
        case "move", "down", "up", "click", "doubleClick", "rightClick": return normalizedPoint(object) != nil
        case "scroll":
            guard let dx = number(object["dx"]), let dy = number(object["dy"]) else { return false }
            return dx.isFinite && dy.isFinite && abs(dx) <= 1000 && abs(dy) <= 1000
        case "text":
            guard let text = object["text"] as? String else { return false }
            return !text.isEmpty && text.utf8.count <= 4096 && !text.unicodeScalars.contains(where: { $0.value == 0 })
        case "key":
            guard let key = object["key"] as? String else { return false }
            return ["enter", "backspace", "delete", "escape", "tab", "left", "right", "up", "down", "home", "end", "copy", "paste", "cut", "selectAll", "undo", "redo"].contains(key)
        default: return false
        }
    }
    /// JSON booleans bridge to NSNumber and must never become coordinates,
    /// protocol versions, or integer statistics through Swift's numeric casts.
    public static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    public static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded(.towardZero) == number,
              number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }
    public static func equalSecret(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
