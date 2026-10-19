import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite
struct WirelessIdentityTests {
    private func service(_ name: String, _ host: String, _ port: Int) -> MDNSService {
        MDNSService(name: name, host: host, port: port, kind: .connect)
    }

    @Test
    func testPortChangeKeepsSelectedIdentityWithIdenticalModelNames() {
        let other = SavedDevice(name: "Pixel 8", host: "192.168.1.3", port: 37001, serviceName: "other-phone")
        var selected = SavedDevice(name: "Pixel 8", host: "192.168.1.2", port: 37002, serviceName: "selected-phone")
        let identity = WirelessSessionIdentity(serial: "192.168.1.2:37002", savedDevices: [other, selected], services: [])
        selected.port = 49001
        let endpoint = identity.reconnectEndpoint(savedDevices: [other, selected], services: [
            service("other-phone", "192.168.1.3", 49002), service("selected-phone", "192.168.1.2", 49001)
        ])
        #expect(identity.savedDeviceID == selected.id)
        #expect(endpoint?.address == "192.168.1.2:49001")
    }

    @Test
    func testMissingNamedServiceDoesNotFollowReusedIP() {
        let selected = SavedDevice(name: "Pixel 8", host: "192.168.1.2", port: 37002, serviceName: "selected-phone")
        let reused = [service("another-phone", selected.host, selected.port)]
        let identity = WirelessSessionIdentity(serial: "192.168.1.2:37002", savedDevices: [selected], services: [])
        #expect(identity.reconnectEndpoint(savedDevices: [selected], services: reused) == nil)
        #expect(WirelessIdentity.reconnectEndpoint(saved: selected, services: reused) == nil)
    }

    @Test
    func testUnknownIdentityNeverAdoptsChangedPortOrSameModel() {
        let saved = SavedDevice(name: "Pixel 8", host: "192.168.1.2", port: 49001)
        let identity = WirelessSessionIdentity(serial: "192.168.1.2:37002", savedDevices: [saved], services: [])
        #expect(identity.savedDeviceID == nil)
        #expect(identity.reconnectEndpoint(savedDevices: [saved], services: [service("other-phone", saved.host, 49001)])?.address == "192.168.1.2:37002")
    }

    @Test
    func testMDNSSerialCanCaptureIdentityWithoutSavedPreference() {
        let identity = WirelessSessionIdentity(serial: "adb-phone._adb-tls-connect._tcp", savedDevices: [], services: [])
        #expect(identity.serviceName == "adb-phone")
        #expect(identity.reconnectEndpoint(savedDevices: [], services: [service("adb-phone", "192.168.1.9", 45001)])?.address == "192.168.1.9:45001")
    }

    @Test
    func testChangedSavedRecordCannotReplaceCapturedIdentity() {
        var saved = SavedDevice(name: "Pixel 8", host: "192.168.1.2", port: 37002, serviceName: "original")
        let identity = WirelessSessionIdentity(serial: "192.168.1.2:37002", savedDevices: [saved], services: [])
        saved.serviceName = "replacement"
        #expect(identity.reconnectEndpoint(savedDevices: [saved], services: [service("original", "192.168.1.8", 45001)]) == nil)
    }

    @Test
    func testRememberDoesNotOverwriteAnotherNamedPhoneAtReusedAddress() throws {
        let saved = SavedDevice(name: "Pixel 8", host: "192.168.1.2", port: 37002, serviceName: "original")
        let endpoint = try WirelessEndpoint(host: saved.host, port: String(saved.port))
        #expect(WirelessIdentity.savedIndex(endpoint: endpoint, serviceName: "new-phone", savedDevices: [saved]) == nil)
        #expect(WirelessIdentity.savedIndex(endpoint: endpoint, serviceName: nil, savedDevices: [saved]) == 0)
    }

    @Test
    func testRememberLegacyRecordRequiresExactEndpoint() throws {
        let legacy = SavedDevice(name: "Pixel 8", host: "192.168.1.2", port: 37002)
        #expect(WirelessIdentity.savedIndex(endpoint: try WirelessEndpoint(host: legacy.host, port: "49001"),
                                                serviceName: "phone", savedDevices: [legacy]) == nil)
        #expect(WirelessIdentity.savedIndex(endpoint: try WirelessEndpoint(host: legacy.host, port: "37002"),
                                                   serviceName: "phone", savedDevices: [legacy]) == 0)
    }

    @Test
    func testConnectionCanResolveADBMDNSAliasWithoutMatchingAnotherDevice() throws {
        let endpoint = try WirelessEndpoint(host: "192.168.1.2", port: "37002")
        let devices = [
            AndroidDevice(serial: "other._adb-tls-connect._tcp", model: "Pixel_8", state: .ready, transport: .wifi),
            AndroidDevice(serial: "selected._adb-tls-connect._tcp", model: "Pixel_8", state: .unauthorized, transport: .wifi)
        ]
        let resolved = WirelessIdentity.device(endpoint: endpoint, services: [service("selected", endpoint.host, endpoint.port)], devices: devices)
        #expect(resolved?.serial == devices[1].serial)
        #expect(resolved?.state == .unauthorized)
        #expect(WirelessIdentity.device(endpoint: endpoint, services: [], devices: devices) == nil)
    }

    @Test
    func testPairingServiceCannotRedirectConnection() {
        let saved = SavedDevice(name: "Phone", host: "192.168.1.2", port: 37002, serviceName: "phone")
        let pairing = MDNSService(name: "phone", host: saved.host, port: 45001, kind: .pairing)
        #expect(WirelessIdentity.reconnectEndpoint(saved: saved, services: [pairing]) == nil)
    }

    @Test
    func testIPv6AndServiceSuffixesRemainExact() {
        #expect(WirelessIdentity.endpoint(address: "[fe80::1%en0]:37002")?.host == "fe80::1%en0")
        #expect(WirelessIdentity.serviceName(serial: "phone._adb-tls-connect._tcp.local.") == "phone")
        #expect(WirelessIdentity.serviceName(serial: "phone._adb-tls-pairing._tcp") == nil)
    }
}
