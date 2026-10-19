import Foundation
import Testing
@testable import AndroidOnMacCore

@Suite
struct CommandBuilderTests {
    @Test
    func testValidEndpointsAndIPv6Brackets() throws {
        let cases = [
            ("192.168.1.2", "37001", "192.168.1.2:37001"),
            (" android.local ", " 1234 ", "android.local:1234"),
            ("phone.example.com.", "65535", "phone.example.com.:65535"),
            ("[2001:db8::1]", "1", "[2001:db8::1]:1"),
            ("fe80::1%en0", "37001", "[fe80::1%en0]:37001"),
            ("[::1]", "00371", "[::1]:371")
        ]
        for (host, port, expected) in cases {
            #expect(try WirelessEndpoint(host: host, port: port).address == expected)
        }
    }

    @Test
    func testRejectsCommandCharactersOptionsAndMalformedHosts() {
        let invalid = ["", " ", "--help", "-server", "host;touch", "$(whoami)", "`id`", "a|b", "a&b",
                       "a/b", "https://phone", "host:1234", "999.1.1.1", "1.2.3", "1.2.3.04", "host name",
                       "host\n", "host\r", "host\t", "host\0", ".host", "a..b", "a-.local", "[host]",
                       "[::1", "::1]", "[::1]:1234", "fe80::1%", "fe80::1%en0%more", "fe80::1%en0;id",
                       String(repeating: "a", count: 64) + ".local"]
        for host in invalid {
            #expect(throws: EndpointError.invalidHost, "Invalid input: \(host)") { try WirelessEndpoint(host: host, port: "1234") }
        }
    }

    @Test
    func testRejectsInvalidPorts() {
        for port in ["", "0", "65536", "-1", "+1234", "1e3", "0x123", "1.2", "12 34", "1234\n", "1234;id", "１２３４", String(repeating: "9", count: 100)] {
            #expect(throws: EndpointError.invalidPort, "Invalid input: \(port)") { try WirelessEndpoint(host: "android.local", port: port) }
        }
    }

    @Test
    func testDefaultsProduceLowLatencyCompatibleFlags() {
        let settings = MirrorSettings()
        #expect(settings.quality == .balanced)
        #expect(settings.keyboard == .sdk)
        #expect(settings.audio)
        #expect(settings.clipboard)
        #expect(!(settings.screenOff))
        #expect(!(settings.fullscreen))
        #expect(!(settings.alwaysOnTop))
        #expect(CommandBuilder.scrcpy(serial: "phone", settings: settings) == [
            "--serial=phone", "--video-codec=h264", "--max-size=1920", "--video-bit-rate=8M",
            "--max-fps=60", "--hwdec=auto", "--keyboard=sdk"
        ])
    }

    @Test
    func testSmoothProfileAndAllToggles() {
        var settings = MirrorSettings()
        settings.quality = .smooth
        settings.audio = false
        settings.clipboard = false
        settings.screenOff = true
        settings.fullscreen = true
        settings.alwaysOnTop = true
        settings.keyboard = .uhid
        let arguments = CommandBuilder.scrcpy(serial: "phone", settings: settings)
        for flag in ["--max-size=1280", "--video-bit-rate=4M", "--keyboard=uhid", "--no-audio",
                     "--no-clipboard-autosync", "--turn-screen-off", "--fullscreen", "--always-on-top"] {
            #expect(arguments.contains(flag), "Missing flag \(flag)")
        }
        // Never terminate a shared adb server or leave a server installed.
        #expect(!(arguments.contains("--kill-adb-on-close")))
        #expect(!(arguments.contains("--no-cleanup")))
        #expect(!(arguments.contains("--legacy-paste")))
    }

    @Test
    func testSerialCannotIntroduceAnotherOptionOrShellCommand() {
        let serial = "--no-control; $(touch /tmp/nope)"
        let arguments = CommandBuilder.scrcpy(serial: serial, settings: MirrorSettings())
        #expect(arguments[0] == "--serial=\(serial)")
        #expect(!(arguments.contains("--no-control")))
        #expect(arguments.count == 7)
    }

    @Test
    func testPairCommandDoesNotPutPairingSecretInArguments() throws {
        let endpoint = try WirelessEndpoint(host: "192.168.1.2", port: "40001")
        #expect(CommandBuilder.pair(endpoint) == ["pair", "192.168.1.2:40001"])
        #expect(CommandBuilder.connect(endpoint) == ["connect", "192.168.1.2:40001"])
        #expect(CommandBuilder.disconnect(endpoint) == ["disconnect", "192.168.1.2:40001"])
    }

    @Test
    func testPreferenceBackwardCompatibilityAndRoundTrip() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(MirrorSettings.self, from: Data("{}".utf8)) == MirrorSettings())
        let legacy = Data(#"{"audio":false,"quality":"old-value","keyboard":"unsupported"}"#.utf8)
        let restored = try decoder.decode(MirrorSettings.self, from: legacy)
        #expect(!(restored.audio))
        #expect(restored.keyboard == .sdk)
        #expect(restored.quality == .balanced)
        #expect(try decoder.decode(MirrorSettings.self, from: JSONEncoder().encode(restored)) == restored)
    }

    @Test
    func testSavedEndpointRoundTripPreservesStableIdentity() throws {
        let original = SavedDevice(name: "我的手机", host: "android.local", port: 37001, serviceName: "adb-phone")
        var refreshed = original
        refreshed.port = 37002
        #expect(refreshed.id == original.id)
        #expect(try JSONDecoder().decode(SavedDevice.self, from: JSONEncoder().encode(refreshed)) == refreshed)
    }

    @Test
    func testOldSavedDeviceWithoutServiceNameStillDecodes() throws {
        let data = Data(#"{"id":"41884A9F-14BF-412D-A88B-6E8EF3F041D6","name":"Pixel","host":"192.168.1.2","port":37001}"#.utf8)
        let saved = try JSONDecoder().decode(SavedDevice.self, from: data)
        #expect(saved.serviceName == nil)
        #expect(saved.host == "192.168.1.2")
        #expect(saved.port == 37001)
    }
}
