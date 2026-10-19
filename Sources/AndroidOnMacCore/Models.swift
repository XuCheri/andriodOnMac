import Foundation

public enum DeviceState: Equatable, Sendable {
    case ready
    case unauthorized
    case offline
    case unknown(String)
}

public enum Transport: String, Codable, CaseIterable, Sendable {
    case usb
    case wifi

    public var displayName: String { self == .usb ? "USB" : "Wi-Fi" }
}

public struct AndroidDevice: Identifiable, Equatable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let model: String
    public let state: DeviceState
    public let transport: Transport
    public var displayName: String {
        model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ")
    }
    public var isReady: Bool { state == .ready }

    public init(serial: String, model: String = "", state: DeviceState, transport: Transport) {
        self.serial = serial
        self.model = model
        self.state = state
        self.transport = transport
    }
}

public enum MDNSKind: String, Codable, CaseIterable, Sendable {
    case pairing
    case connect
}

public struct MDNSService: Identifiable, Equatable, Sendable {
    // A restart may change the port without creating a different service identity.
    public var id: String { "\(kind.rawValue):\(name)" }
    public let name: String
    public let host: String
    public let port: Int
    public let kind: MDNSKind

    public init(name: String, host: String, port: Int, kind: MDNSKind) {
        self.name = name
        self.host = host
        self.port = port
        self.kind = kind
    }
}

public struct SavedDevice: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    /// Last known connection port only; refresh it from mDNS when available.
    public var port: Int
    public var serviceName: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int, serviceName: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.serviceName = serviceName
    }
}

public enum QualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced
    case smooth

    public var id: String { rawValue }
    public var displayName: String { self == .balanced ? "均衡 · 1920 / 8 Mbps" : "流畅 · 1280 / 4 Mbps" }
}

public enum KeyboardMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sdk
    case uhid

    public var id: String { rawValue }
    public var displayName: String { self == .sdk ? "标准输入（支持剪贴板粘贴）" : "模拟物理键盘（UHID）" }
}

public struct MirrorSettings: Codable, Equatable, Sendable {
    public var quality: QualityPreset = .balanced
    public var audio = true
    public var clipboard = true
    public var screenOff = false
    public var alwaysOnTop = false
    public var fullscreen = false
    public var keyboard: KeyboardMode = .sdk

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case quality, audio, clipboard, screenOff, alwaysOnTop, fullscreen, keyboard
    }

    /// Older preferences may omit newly introduced options. Unknown enum values
    /// also fall back to the safe defaults rather than discarding every setting.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quality = (try? values.decode(QualityPreset.self, forKey: .quality)) ?? .balanced
        audio = try values.decodeIfPresent(Bool.self, forKey: .audio) ?? true
        clipboard = try values.decodeIfPresent(Bool.self, forKey: .clipboard) ?? true
        screenOff = try values.decodeIfPresent(Bool.self, forKey: .screenOff) ?? false
        alwaysOnTop = try values.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
        fullscreen = try values.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? false
        keyboard = (try? values.decode(KeyboardMode.self, forKey: .keyboard)) ?? .sdk
    }
}
