import XCTest
@testable import AndroidOnMacCore

final class DeviceParserTests: XCTestCase {
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

    func testDevicesPreservesStatesAndSelectsTransport() {
        let devices = ADBParser.devices(devicesFixture)
        XCTAssertEqual(devices.count, 6)
        XCTAssertEqual(devices[0].transport, .usb)
        XCTAssertEqual(devices[0].model, "SM_G973U1")
        XCTAssertEqual(devices[1].transport, .wifi)
        XCTAssertEqual(devices[1].displayName, "Pixel 7")
        XCTAssertEqual(devices[2].transport, .wifi)
        XCTAssertEqual(devices[3].state, .unauthorized)
        XCTAssertFalse(devices[3].isReady)
        XCTAssertEqual(devices[4].state, .offline)
        XCTAssertEqual(devices[4].transport, .wifi)
        XCTAssertEqual(devices[5].state, .unknown("recovery"))
        XCTAssertEqual(devices.map(\.id), devices.map(\.serial))
    }

    func testMissingModelsAndNoPermissionState() {
        let devices = ADBParser.devices("phone\tno permissions (missing udev rules)\nother\tdevice\n")
        XCTAssertEqual(devices.first?.state, .unknown("no permissions"))
        XCTAssertEqual(devices.last?.displayName, "other")
        XCTAssertTrue(devices.last!.isReady)
    }

    func testIgnoresDiagnosticsHeadersDuplicatesAndMalformedLines() {
        let output = "List of devices attached\r\n\r\n" +
            "adb: error: more than one device/emulator\n" +
            "error: cannot connect\nrandom diagnostic text\n" +
            "phone device model:Pixel_7\nphone\tdevice model:duplicate\n" +
            "--option\tdevice\nsingle-field\n"
        XCTAssertEqual(ADBParser.devices(output).map(\.serial), ["phone"])
        XCTAssertEqual(ADBParser.devices("").count, 0)
    }

    func testUnknownStateIsRetainedButCannotMirror() {
        let devices = ADBParser.devices("phone\tfuture-state model:Future_Phone")
        XCTAssertEqual(devices.first?.state, .unknown("future-state"))
        XCTAssertEqual(devices.first?.isReady, false)
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

    func testMDNSSeparatesPairingAndConnectPorts() {
        let services = ADBParser.mdns(mdnsFixture)
        XCTAssertEqual(services.count, 4)
        XCTAssertEqual(services[0].kind, .pairing)
        XCTAssertEqual(services[0].port, 33861)
        XCTAssertEqual(services[1].kind, .connect)
        XCTAssertEqual(services[1].port, 33015)
        XCTAssertEqual(services[2].host, "fe80::42%en0")
        XCTAssertEqual(services[3].host, "android.local")
    }

    func testMDNSRefreshesChangedPortWithoutChangingIdentity() {
        let first = ADBParser.mdns("phone _adb-tls-connect._tcp 192.168.1.2:37001")[0]
        let refreshed = ADBParser.mdns("phone _adb-tls-connect._tcp 192.168.1.2:37001\nphone _adb-tls-connect._tcp 192.168.1.2:37002")
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed[0].id, first.id)
        XCTAssertEqual(refreshed[0].port, 37002)
        let paired = MDNSService(name: "phone", host: first.host, port: 40001, kind: .pairing)
        XCTAssertNotEqual(paired.id, first.id)
    }

    func testMDNSRejectsInvalidEndpointAndDiagnosticLines() {
        let output = """
        adb: failed to discover services
        invalid _adb-tls-connect._tcp --option:5000
        invalid2 _adb-tls-connect._tcp 192.168.1.2:0
        invalid3 _adb-tls-pairing._tcp host;command:1234
        incomplete _adb-tls-connect._tcp
        """
        XCTAssertEqual(ADBParser.mdns(output), [])
    }
}
