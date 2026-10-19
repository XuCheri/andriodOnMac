import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite
struct DeviceParserTests {
    // Representative adb devices -l output, including Android's TLS mDNS serial.
    private let devicesFixture = """
    * daemon not running; starting now at tcp:5037
    * daemon started successfully
    List of devices attached
    R58M123ABCD\tdevice usb:336592896X product:beyond1qlteue model:SM_G973U1 device:beyond1q transport_id:1
    192.168.1.23:37951\tdevice product:panther model:Pixel_7 device:panther transport_id:2
    adb-35121FDJH000R8-xyMD0H._adb-tls-connect._tcp\tdevice product:shiba model:Pixel_8 device:shiba transport_id:3
    unauthorized-phone\tunauthorized usb:337641472X transport_id:4
    [fe80::1234%en0]:42541\toffline transport_id:5
    recovery-phone\trecovery usb:1-1 model:Recovery_Device
    """

    @Test
    func testDevicesPreservesStatesAndSelectsTransport() throws {
        let devices = ADBParser.devices(devicesFixture)
        try #require(devices.count == 6)
        #expect(devices[0].transport == .usb)
        #expect(devices[0].model == "SM_G973U1")
        #expect(devices[1].transport == .wifi)
        #expect(devices[1].displayName == "Pixel 7")
        #expect(devices[2].transport == .wifi)
        #expect(devices[3].state == .unauthorized)
        #expect(!(devices[3].isReady))
        #expect(devices[4].state == .offline)
        #expect(devices[4].transport == .wifi)
        #expect(devices[5].state == .unknown("recovery"))
        #expect(devices.map(\.id) == devices.map(\.serial))
    }

    @Test
    func testMissingModelsAndNoPermissionState() throws {
        let devices = ADBParser.devices("phone\tno permissions (missing udev rules)\nother\tdevice\n")
        #expect(devices.first?.state == .unknown("no permissions"))
        #expect(devices.last?.displayName == "other")
        let last = try #require(devices.last)
        #expect(last.isReady)
    }

    @Test
    func testIgnoresDiagnosticsHeadersDuplicatesAndMalformedLines() {
        let output = "List of devices attached\r\n\r\n" +
            "adb: error: more than one device/emulator\n" +
            "error: cannot connect\nrandom diagnostic text\n" +
            "phone device model:Pixel_7\nphone\tdevice model:duplicate\n" +
            "--option\tdevice\nsingle-field\n"
        #expect(ADBParser.devices(output).map(\.serial) == ["phone"])
        #expect(ADBParser.devices("").count == 0)
    }

    @Test
    func testUnknownStateIsRetainedButCannotMirror() {
        let devices = ADBParser.devices("phone\tfuture-state model:Future_Phone")
        #expect(devices.first?.state == .unknown("future-state"))
        #expect(devices.first?.isReady == false)
    }

    // Mirrors adb's documented three-column output; the two ports are distinct.
    private let mdnsFixture = """
    List of discovered mdns services
    adb-14141FDF600081-QXjCrW  _adb-tls-pairing._tcp  192.168.86.38:33861
    adb-14141FDF600081-TnSdi9  _adb-tls-connect._tcp  192.168.86.38:33015
    adb-oldphone             _adb._tcp             192.168.86.40:5555
    adb-v6                   _adb-tls-connect._tcp. [fe80::42%en0]:37123
    studio-qr                _adb-tls-pairing._tcp  android.local:55861
    """

    @Test
    func testMDNSSeparatesPairingAndConnectPorts() throws {
        let services = ADBParser.mdns(mdnsFixture)
        try #require(services.count == 4)
        #expect(services[0].kind == .pairing)
        #expect(services[0].port == 33861)
        #expect(services[1].kind == .connect)
        #expect(services[1].port == 33015)
        #expect(services[2].host == "fe80::42%en0")
        #expect(services[3].host == "android.local")
    }

    @Test
    func testMDNSRefreshesChangedPortWithoutChangingIdentity() throws {
        let first = try #require(ADBParser.mdns("phone _adb-tls-connect._tcp 192.168.1.2:37001").first)
        let refreshed = ADBParser.mdns("phone _adb-tls-connect._tcp 192.168.1.2:37001\nphone _adb-tls-connect._tcp 192.168.1.2:37002")
        try #require(refreshed.count == 1)
        #expect(refreshed[0].id == first.id)
        #expect(refreshed[0].port == 37002)
        let paired = MDNSService(name: "phone", host: first.host, port: 40001, kind: .pairing)
        #expect(paired.id != first.id)
    }

    @Test
    func testMDNSRejectsInvalidEndpointAndDiagnosticLines() {
        let output = """
        adb: failed to discover services
        invalid _adb-tls-connect._tcp --option:5000
        invalid2 _adb-tls-connect._tcp 192.168.1.2:0
        invalid3 _adb-tls-pairing._tcp host;command:1234
        incomplete _adb-tls-connect._tcp
        """
        #expect(ADBParser.mdns(output) == [])
    }
}
