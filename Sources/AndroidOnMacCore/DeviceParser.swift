import Foundation

public enum ADBParser {
    public static func devices(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        var seen = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("*"),
                  !line.hasPrefix("adb:"), !line.hasPrefix("List of devices"),
                  !line.hasPrefix("error:"), !line.hasPrefix("daemon") else { continue }
            let serial = fields[0]
            let status = fields[1]
            // adb rows use a tab between serial and status; known states also
            // tolerate spaces (as used by some tools when copying the output).
            let knownStates = ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no"]
            guard line.contains("\t") || knownStates.contains(status), !serial.hasPrefix("-"),
                  !serial.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(serial).inserted else { continue }
            let state: DeviceState
            switch status {
            case "device": state = .ready
            case "unauthorized": state = .unauthorized
            case "offline": state = .offline
            case "no" where fields.count >= 3 && fields[2] == "permissions": state = .unknown("no permissions")
            default: state = .unknown(status)
            }
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
            let hasUSB = fields.contains(where: { $0.hasPrefix("usb:") })
            let isWireless = serial.contains("_adb-tls-connect._tcp") || endpoint(serial) != nil
            devices.append(AndroidDevice(serial: serial, model: model, state: state,
                                         transport: hasUSB ? .usb : (isWireless ? .wifi : .usb)))
        }
        return devices
    }

    public static func mdns(_ output: String) -> [MDNSService] {
        var services: [MDNSService] = []
        var indices: [String: Int] = [:]
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 3 else { continue }
            let kind: MDNSKind
            switch fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            case "_adb-tls-pairing._tcp": kind = .pairing
            case "_adb-tls-connect._tcp": kind = .connect
            default: continue
            }
            guard let address = endpoint(fields[2]) else { continue }
            let service = MDNSService(name: fields[0], host: address.host, port: address.port, kind: kind)
            if let index = indices[service.id] {
                services[index] = service
            } else {
                indices[service.id] = services.count
                services.append(service)
            }
        }
        return services
    }

    private static func endpoint(_ address: String) -> WirelessEndpoint? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        let host = String(address[..<colon])
        let port = String(address[address.index(after: colon)...])
        return try? WirelessEndpoint(host: host, port: port)
    }
}
