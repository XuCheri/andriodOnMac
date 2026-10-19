import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum EndpointError: Error, Equatable, LocalizedError {
    case invalidHost
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "请输入有效的 IP 地址或主机名，不要包含协议、端口或命令字符。"
        case .invalidPort: return "端口必须是 1 到 65535 之间的整数。"
        }
    }
}

public struct WirelessEndpoint: Equatable, Sendable {
    /// Unbracketed host; `address` adds brackets for IPv6.
    public let host: String
    public let port: Int
    public var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    public init(host: String, port: String) throws {
        guard !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw EndpointError.invalidHost
        }
        var candidate = host.trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix("[") && candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst().dropLast())
            guard candidate.contains(":") else { throw EndpointError.invalidHost }
        }
        guard Self.validHost(candidate) else { throw EndpointError.invalidHost }
        let portText = port.trimmingCharacters(in: .whitespaces)
        guard !portText.isEmpty,
              portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(portText), (1...65535).contains(number) else {
            throw EndpointError.invalidPort
        }
        self.host = candidate
        self.port = number
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if host.contains(":") {
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            if parts.count == 2 {
                let zone = parts[1]
                guard !zone.isEmpty, zone.utf8.count <= 64,
                      zone.utf8.allSatisfy({ isASCIIAlphanumeric($0) || [45, 46, 95].contains($0) }) else {
                    return false
                }
            }
            var bytes = in6_addr()
            return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &bytes) } == 1
        }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            // inet_pton accepts leading zeroes on some Darwin releases. Keep
            // addresses unambiguous and validation consistent across macOS.
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            return octets.count == 4 && octets.allSatisfy { octet in
                guard !octet.isEmpty, octet.count <= 3,
                      octet.count == 1 || octet.first != "0",
                      let number = Int(octet) else { return false }
                return number <= 255
            }
        }
        let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        return hostname.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard let first = label.utf8.first, let last = label.utf8.last,
                  label.utf8.count <= 63, isASCIIAlphanumeric(first), isASCIIAlphanumeric(last) else {
                return false
            }
            return label.utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == 45 }
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

public enum CommandBuilder {
    /// Arguments are passed to Process directly, never through a shell. The
    /// equals form keeps even an untrusted serial inside the option's value.
    public static func scrcpy(serial: String, settings: MirrorSettings) -> [String] {
        var arguments = [
            "--serial=\(serial)",
            "--video-codec=h264",
            "--max-size=\(settings.quality == .balanced ? 1920 : 1280)",
            "--video-bit-rate=\(settings.quality == .balanced ? "8M" : "4M")",
            "--max-fps=60",
            "--hwdec=auto",
            "--keyboard=\(settings.keyboard.rawValue)"
        ]
        if !settings.audio { arguments.append("--no-audio") }
        if !settings.clipboard { arguments.append("--no-clipboard-autosync") }
        if settings.screenOff { arguments.append("--turn-screen-off") }
        if settings.alwaysOnTop { arguments.append("--always-on-top") }
        if settings.fullscreen { arguments.append("--fullscreen") }
        return arguments
    }

    public static func connect(_ endpoint: WirelessEndpoint) -> [String] { ["connect", endpoint.address] }
    public static func pair(_ endpoint: WirelessEndpoint) -> [String] { ["pair", endpoint.address] }
    public static func disconnect(_ endpoint: WirelessEndpoint) -> [String] { ["disconnect", endpoint.address] }
}
