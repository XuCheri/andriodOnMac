import Foundation
import Testing
import AndroidOnMacCore
@testable import MacDisplayTransport

@Suite struct DisplayTransportPolicyTests {
    @Test func discoveryContainsOnlyPublicFingerprintAndProtocolVersion() {
        let fingerprint = String(repeating: "a1", count: 32)
        let record = NetService.dictionary(fromTXTRecord: DisplayServer.discoveryRecord(fingerprint: fingerprint))
        #expect(Set(record.keys) == Set(["fingerprint", "v"]))
        #expect(record["fingerprint"] == Data(fingerprint.utf8))
        #expect(record["v"] == Data("1".utf8))
    }
    @Test func localAddressValidationRejectsMalformedAndPublicAddresses() {
        for address in ["127.0.0.1", "10.1.2.3", "192.168.255.2", "172.16.0.1", "172.31.255.255", "169.254.1.1", "::1", "fe80::1%en0", "febf::1", "fd12::1", "FC00::1"] {
            #expect(DisplayServer.isLocalAddress(address), "Rejected private address: \(address)")
        }
        for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "2001:4860:4860::8888", "fe80:garbage", "fdfake", "10.foo.0.0.1", "10.0.0.1.1", "127.0.0.256", "127.1", "localhost", "::", "ff02::1", "::ffff:127.0.0.1", "127.0.0.1%en0", "fe80::1%", "fe80::1%en0%foo"] {
            #expect(!DisplayServer.isLocalAddress(address), "Accepted invalid/public address: \(address)")
        }
    }

    @Test func connectionEpochRejectsOldMediaAfterReconnectAndStop() {
        let state = DisplayConnectionState()
        state.advance(); let first = state.generation
        #expect(state.reserve(bytes: 10, generation: first)); state.release(bytes: 10)
        state.advance(); let disconnected = state.generation
        state.advance(); let next = state.generation
        #expect(first != disconnected && disconnected != next)
        #expect(!state.reserve(bytes: 10, generation: first))
        #expect(!state.reserve(bytes: 10, generation: disconnected))
        #expect(state.reserve(bytes: 10, generation: next)); state.release(bytes: 10)
        state.stop(); let stopped = state.generation
        #expect(state.activeGeneration == nil)
        #expect(!state.reserve(bytes: 10, generation: next))
        #expect(!state.reserve(bytes: 10, generation: stopped))
        state.stop(); #expect(state.generation == stopped)
    }

    @Test func producerAdmissionBoundsBothBytesAndPendingWork() {
        let state = DisplayConnectionState(), epoch: UInt64 = 0
        #expect(!state.reserve(bytes: -1, generation: epoch))
        #expect(!state.reserve(bytes: ReverseFrame.maximumBody + 5, generation: epoch))
        #expect(state.reserve(bytes: ReverseFrame.maximumBody + 4, generation: epoch))
        #expect(!state.reserve(bytes: 1, generation: epoch))
        state.release(bytes: ReverseFrame.maximumBody + 4)
        for _ in 0..<16 { #expect(state.reserve(bytes: 1, generation: epoch)) }
        #expect(!state.reserve(bytes: 1, generation: epoch))
        state.release(bytes: 1); #expect(state.reserve(bytes: 1, generation: epoch))
        #expect(state.markCongestion(generation: epoch)); #expect(!state.markCongestion(generation: epoch))
        state.clearCongestion(); #expect(state.markCongestion(generation: epoch))
        state.advance(); #expect(!state.markCongestion(generation: epoch))
    }

    @Test func allMessagesAreRateLimitedIncludingPendingPairingHeartbeats() {
        var unauthenticated = DisplayMessageRateLimit()
        for _ in 0..<20 { let accepted = unauthenticated.accept(now: 10, authenticated: false); #expect(accepted) }
        let overflow = unauthenticated.accept(now: 10.99, authenticated: false); #expect(!overflow)
        let nextWindow = unauthenticated.accept(now: 11, authenticated: false); #expect(nextWindow)
        var authenticated = DisplayMessageRateLimit()
        for _ in 0..<600 { let accepted = authenticated.accept(now: 1, authenticated: true); #expect(accepted) }
        let flood = authenticated.accept(now: 1.9, authenticated: true); #expect(!flood)
        let reset = authenticated.accept(now: 2, authenticated: true); #expect(reset)
    }
}
