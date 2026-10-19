import Foundation

/// Captured once for a user-selected session. Display names and IP addresses
/// alone must never redirect that session to a different discovered phone.
public struct WirelessSessionIdentity: Equatable, Sendable {
    public let serial: String
    public let savedDeviceID: UUID?
    public let serviceName: String?

    public init(serial: String, savedDevices: [SavedDevice], services: [MDNSService]) {
        self.serial = serial
        let service = WirelessIdentity.service(serial: serial, services: services)
        let name = service?.name ?? WirelessIdentity.serviceName(serial: serial)
        let saved = savedDevices.first {
            if let name { return $0.serviceName == name }
            return WirelessIdentity.endpoint(host: $0.host, port: $0.port)?.address == serial
        }
        savedDeviceID = saved?.id
        serviceName = name ?? saved?.serviceName
    }

    public func reconnectEndpoint(savedDevices: [SavedDevice], services: [MDNSService]) -> WirelessEndpoint? {
        // The ID locates the same record; the captured service name prevents a
        // later record update from silently changing the selected identity.
        let saved = savedDevices.first { $0.id == savedDeviceID }
        if let name = serviceName {
            guard saved == nil || saved?.serviceName == nil || saved?.serviceName == name,
                  let service = services.first(where: { $0.kind == .connect && $0.name == name }) else { return nil }
            return WirelessIdentity.endpoint(host: service.host, port: service.port)
        }
        // Without a discovered identity only the original, exact address is safe
        // to reuse. Never adopt another port by model name or host-only matching.
        return WirelessIdentity.endpoint(address: serial)
    }
}

public enum WirelessIdentity {
    public static func endpoint(host: String, port: Int) -> WirelessEndpoint? {
        try? WirelessEndpoint(host: host, port: String(port))
    }

    public static func endpoint(address: String) -> WirelessEndpoint? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return try? WirelessEndpoint(host: String(address[..<colon]), port: String(address[address.index(after: colon)...]))
    }

    public static func serviceName(serial: String) -> String? {
        for suffix in ["._adb-tls-connect._tcp", "._adb-tls-connect._tcp.", "._adb-tls-connect._tcp.local."] {
            if serial.hasSuffix(suffix) {
                let name = String(serial.dropLast(suffix.count))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    public static func service(serial: String, services: [MDNSService]) -> MDNSService? {
        if let name = serviceName(serial: serial) {
            return services.first { $0.kind == .connect && $0.name == name }
        }
        return services.first { $0.kind == .connect && endpoint(host: $0.host, port: $0.port)?.address == serial }
    }

    public static func reconnectEndpoint(saved: SavedDevice, services: [MDNSService]) -> WirelessEndpoint? {
        if let name = saved.serviceName {
            guard let service = services.first(where: { $0.kind == .connect && $0.name == name }) else { return nil }
            return endpoint(host: service.host, port: service.port)
        }
        return endpoint(host: saved.host, port: saved.port)
    }

    /// Matching an existing preference requires a stable service name, or the
    /// entire original endpoint when no service identity is available.
    public static func savedIndex(endpoint: WirelessEndpoint, serviceName: String?, savedDevices: [SavedDevice]) -> Int? {
        if let serviceName {
            if let index = savedDevices.firstIndex(where: { $0.serviceName == serviceName }) { return index }
            return savedDevices.firstIndex { $0.serviceName == nil && self.endpoint(host: $0.host, port: $0.port) == endpoint }
        }
        return savedDevices.firstIndex { self.endpoint(host: $0.host, port: $0.port) == endpoint }
    }

    public static func device(endpoint: WirelessEndpoint, services: [MDNSService], devices: [AndroidDevice]) -> AndroidDevice? {
        if let exact = devices.first(where: { $0.serial == endpoint.address }) { return exact }
        guard let service = service(serial: endpoint.address, services: services) else { return nil }
        return devices.first { serviceName(serial: $0.serial) == service.name }
    }
}
