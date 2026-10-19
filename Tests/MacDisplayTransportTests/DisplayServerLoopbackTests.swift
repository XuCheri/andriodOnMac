import Foundation
import Network
import Security
import CryptoKit
import Testing
import AndroidOnMacCore
@testable import MacDisplayTransport

/// Uses fresh ephemeral certificates and an in-memory trust store. It never
/// opens the user's transport identity, reads device data, or uses ADB.
@Suite(.serialized) struct DisplayServerLoopbackTests {
    @Test func authenticatedTLSReconnectRejectsOldMediaAndInputBeforeFirstFrame() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get()
        let events = EventLog(), store = TestTrustStore()
        let server = DisplayServer(readTrust: { store.read() }, saveTrust: { store.write($0) })
        defer { server.stop() }
        let listening = try await server.start(identity: identity, lan: false, onEvent: events.append)
        let deviceID = UUID().uuidString
        let control = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { control.stop() }
        try await control.ready()
        try control.send(hello(id: deviceID, channel: "control", extra: ["pairToken": listening.token]))
        try await until { events.pairID != nil }
        server.approve(try #require(events.pairID))
        let paired = try await control.object(type: "paired")
        let token = try #require(paired["authToken"] as? String), session = try #require(paired["sessionID"] as? String)
        let epoch = server.connectionGeneration
        let media = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { media.stop() }
        try await media.ready()
        try media.send(hello(id: deviceID, channel: "media", extra: ["authToken": token, "sessionID": session]))
        try await until { events.readyCount == 1 }
        try control.send(["type": "input", "action": "click", "x": 0.5, "y": 0.5])
        try control.send(["type": "ping"]); _ = try await control.object(type: "pong")
        #expect(events.inputCount == 0)
        try control.send(["type": "firstFrame"])
        try control.send(["type": "input", "action": "text", "text": "真实 TLS 中文输入"])
        try await until { events.inputCount == 1 }
        #expect(events.lastInputEpoch == epoch)
        control.stop()
        try await until { server.connectionGeneration != epoch }
        let nextControl = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { nextControl.stop() }
        try await nextControl.ready()
        try nextControl.send(hello(id: deviceID, channel: "control", extra: ["authToken": token]))
        let nextPaired = try await nextControl.object(type: "paired")
        let nextSession = try #require(nextPaired["sessionID"] as? String)
        #expect(nextSession != session)
        let nextEpoch = server.connectionGeneration
        let obsoleteMedia = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { obsoleteMedia.stop() }
        try await obsoleteMedia.ready()
        try obsoleteMedia.send(hello(id: deviceID, channel: "media", extra: ["authToken": token, "sessionID": session]))
        _ = try await obsoleteMedia.object(type: "error")
        let nextMedia = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { nextMedia.stop() }
        try await nextMedia.ready()
        try nextMedia.send(hello(id: deviceID, channel: "media", extra: ["authToken": token, "sessionID": nextSession]))
        try await until { events.readyCount == 2 }
        server.send(try .json(["type": "testOldEpoch"]), generation: epoch)
        server.send(try .json(["type": "testCurrentEpoch"]), generation: nextEpoch)
        _ = try await nextMedia.object(type: "testCurrentEpoch")
        #expect(!nextMedia.contains(type: "testOldEpoch"))
        try nextControl.send(["type": "input", "action": "key", "key": "enter"])
        try nextControl.send(["type": "ping"]); _ = try await nextControl.object(type: "pong")
        #expect(events.inputCount == 1)
        server.stop()
        _ = try await nextControl.object(type: "stopped")
        #expect(server.connectionGeneration != nextEpoch)
    }

    @Test func failedTrustPersistenceCannotAuthenticateUsingUncommittedToken() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get(), events = EventLog(), attemptedStore = TestTrustStore()
        let server = DisplayServer(readTrust: { nil }, saveTrust: { data in
            attemptedStore.write(data); throw LoopbackError.store
        })
        defer { server.stop() }
        let listening = try await server.start(identity: identity, lan: false, onEvent: events.append)
        let client = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { client.stop() }
        try await client.ready()
        let deviceID = UUID().uuidString
        try client.send(hello(id: deviceID, channel: "control", extra: ["pairToken": listening.token]))
        try await until { events.pairID != nil }
        server.approve(try #require(events.pairID))
        _ = try await client.object(type: "error")
        #expect(!client.contains(type: "paired"))
        #expect(server.connectionGeneration == 0)
        #expect(events.readyCount == 0)
        let attempted = try JSONDecoder().decode([TrustedReceiver].self, from: #require(attemptedStore.read()))
        let uncommittedToken = try #require(attempted.first?.token)
        try await until { events.pairingWasCancelled }
        let retry = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { retry.stop() }
        try await retry.ready()
        try retry.send(hello(id: deviceID, channel: "control", extra: ["authToken": uncommittedToken]))
        _ = try await retry.object(type: "error")
        #expect(!retry.contains(type: "paired"))
        #expect(server.connectionGeneration == 0)
    }

    @Test func stopBeforeReadyAndCancellationAlwaysFinishStartAndInstanceIsSingleUse() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get()
        for mode in 0..<12 {
            let server = DisplayServer(readTrust: { nil }, saveTrust: { _ in })
            let completion = Completion()
            let task = Task {
                defer { completion.finish() }
                do { _ = try await server.start(identity: identity, lan: false) { _, _ in } }
                catch { }
            }
            if mode % 2 == 0 { server.stop() } else { task.cancel() }
            try await until { completion.done }
            server.stop()
            do {
                _ = try await server.start(identity: identity, lan: false) { _, _ in }
                Issue.record("A stopped/single-use server unexpectedly restarted")
            } catch { }
        }
    }

    @Test func clientWithWrongCertificatePinCannotPair() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get(), events = EventLog()
        let server = DisplayServer(readTrust: { nil }, saveTrust: { _ in })
        defer { server.stop() }
        let listening = try await server.start(identity: identity, lan: false, onEvent: events.append)
        let client = TLSClient(port: listening.port, fingerprint: String(repeating: "0", count: 64))
        defer { client.stop() }
        try await until { client.certificateRejected && client.failed }
        #expect(events.pairID == nil)
        #expect(server.connectionGeneration == 0)
    }

    @Test func blockedTrustReadDoesNotDelayStopOrTaskCancellation() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get()
        for cancelTask in [false, true] {
            let blocked = BlockedSecurityCall(), completion = Completion(), events = EventLog()
            defer { blocked.release() }
            let server = DisplayServer(readTrust: { blocked.wait(); return nil }, saveTrust: { _ in })
            defer { server.stop() }
            let task = Task {
                defer { completion.finish() }
                do { _ = try await server.start(identity: identity, lan: false, onEvent: events.append); return false }
                catch { return error is CancellationError }
            }
            try await until { blocked.entered.done }
            let started = ProcessInfo.processInfo.systemUptime
            if cancelTask { task.cancel() } else { server.stop() }
            try await until { completion.done }
            #expect(ProcessInfo.processInfo.systemUptime - started < 1)
            #expect(await task.value)
            #expect(!blocked.exited.done)
            let stoppedEpoch = server.connectionGeneration
            blocked.release()
            try await until { blocked.exited.done }
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(server.connectionGeneration == stoppedEpoch)
            #expect(events.readyCount == 0)
        }
    }

    @Test func blockedTrustReadHasAnAuthorizationTimeoutAndIgnoresLateSuccess() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get(), blocked = BlockedSecurityCall(), completion = Completion()
        defer { blocked.release() }
        let server = DisplayServer(readTrust: { blocked.wait(); return nil }, saveTrust: { _ in }, securityTimeout: 0.1)
        defer { server.stop() }
        let task = Task {
            defer { completion.finish() }
            do { _ = try await server.start(identity: identity, lan: false) { _, _ in }; return "unexpected success" }
            catch { return error.localizedDescription }
        }
        try await until { blocked.entered.done }
        try await until { completion.done }
        #expect(!blocked.exited.done)
        let message = await task.value
        #expect(message.contains("钥匙串授权超时"))
        #expect(message.contains("原有连接身份已保留"))
        let stoppedEpoch = server.connectionGeneration
        blocked.release(); try await until { blocked.exited.done }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(server.connectionGeneration == stoppedEpoch)
    }

    @Test func blockedTrustWriteCannotHoldStopOrAuthenticateAnObsoletePeer() async throws {
        guard #available(macOS 15.0, *) else { return }
        let identity = try await LoopbackIdentity.shared.get(), blocked = BlockedSecurityCall(), events = EventLog()
        defer { blocked.release() }
        let server = DisplayServer(readTrust: { nil }, saveTrust: { _ in blocked.wait() })
        defer { server.stop() }
        let listening = try await server.start(identity: identity, lan: false, onEvent: events.append)
        let client = TLSClient(port: listening.port, fingerprint: identity.fingerprint)
        defer { client.stop() }
        try await client.ready()
        try client.send(hello(id: UUID().uuidString, channel: "control", extra: ["pairToken": listening.token]))
        try await until { events.pairID != nil }
        server.approve(try #require(events.pairID))
        try await until { blocked.entered.done }
        let started = ProcessInfo.processInfo.systemUptime
        server.stop()
        try await until { client.closed }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        #expect(!blocked.exited.done)
        let stoppedEpoch = server.connectionGeneration
        blocked.release(); try await until { blocked.exited.done }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(server.connectionGeneration == stoppedEpoch)
        #expect(events.readyCount == 0)
        #expect(!client.contains(type: "paired"))
    }

    @Test func identityReadCancellationNeverContinuesIntoCreationOrWrites() async throws {
        let blocked = BlockedSecurityCall(), completion = Completion(), wrote = Completion()
        let processes = ProcessSupervisor()
        defer { blocked.release(); processes.shutdown() }
        let task = Task {
            defer { completion.finish() }
            do {
                _ = try await TransportIdentity.load(processes: processes,
                    read: { _ in blocked.wait(); return nil }, write: { _, _ in wrote.finish() })
                return false
            } catch { return error is CancellationError }
        }
        try await until { blocked.entered.done }
        task.cancel()
        try await until { completion.done }
        #expect(await task.value)
        #expect(!blocked.exited.done)
        blocked.release(); try await until { blocked.exited.done }
        _ = try await TransportSecurityWork.run { _ in true } // Drain the serial worker, not the blocked system call.
        #expect(!wrote.done)
        #expect(processes.activeCount == 0)
    }

    @Test func partialOrDeniedIdentityReadsNeverGenerateReplacementIdentity() async throws {
        let processes = ProcessSupervisor(), wrote = Completion()
        defer { processes.shutdown() }
        for mode in 0..<3 {
            do {
                _ = try await TransportIdentity.load(processes: processes, read: { account in
                    if mode == 2 { throw LoopbackError.store }
                    if mode == 0 { return account == "tls-pkcs12" ? Data([1, 2, 3]) : nil }
                    return account == "tls-password" ? Data("existing".utf8) : nil
                }, write: { _, _ in wrote.finish() })
                Issue.record("Incomplete or inaccessible identity was silently replaced")
            } catch {
                if mode != 2 { #expect(error.localizedDescription.contains("未创建替代身份")) }
            }
        }
        #expect(!wrote.done)
        #expect(processes.activeCount == 0)
    }

    @Test func cancelledQueuedSecurityWorkIsSkippedAfterEarlierSystemPromptReturns() async throws {
        let blocked = BlockedSecurityCall(), firstDone = Completion(), secondDone = Completion(), secondRan = Completion()
        defer { blocked.release() }
        let first = Task {
            defer { firstDone.finish() }
            _ = try? await TransportSecurityWork.run { _ in blocked.wait() }
        }
        try await until { blocked.entered.done }
        let second = Task {
            defer { secondDone.finish() }
            _ = try? await TransportSecurityWork.run { _ in secondRan.finish() }
        }
        second.cancel(); first.cancel()
        try await until { firstDone.done && secondDone.done }
        #expect(!blocked.exited.done)
        blocked.release(); try await until { blocked.exited.done }
        _ = try await TransportSecurityWork.run { _ in true }
        #expect(!secondRan.done)
    }

    private func hello(id: String, channel: String, extra: [String: Any]) -> [String: Any] {
        ["type": "hello", "protocolVersion": 1, "deviceID": id, "deviceName": "隔离测试接收端", "channel": channel]
            .merging(extra) { _, rhs in rhs }
    }
}

private enum LoopbackError: Error { case timeout, store, openssl, identity }
private func until(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw LoopbackError.timeout }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private final class Completion: @unchecked Sendable {
    private let lock = NSLock(); private var completed = false
    var done: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func finish() { lock.lock(); completed = true; lock.unlock() }
}
private final class BlockedSecurityCall: @unchecked Sendable {
    let entered = Completion(), exited = Completion()
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { entered.finish(); semaphore.wait(); exited.finish() }
    func release() { semaphore.signal() }
}
private final class TestTrustStore: @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data) { lock.lock(); data = value; lock.unlock() }
}
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [(DisplayServerEvent, UInt64)] = []
    func append(_ event: DisplayServerEvent, _ generation: UInt64) { lock.lock(); values.append((event, generation)); lock.unlock() }
    var pairID: UUID? {
        lock.lock(); defer { lock.unlock() }
        for (event, _) in values.reversed() { if case .pairing(let id, _) = event { return id } }; return nil
    }
    var readyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return values.filter { if case .receiverReady = $0.0 { return true }; return false }.count
    }
    var pairingWasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains { if case .pairingCancelled = $0.0 { return true }; return false }
    }
    var inputCount: Int {
        lock.lock(); defer { lock.unlock() }
        return values.filter { if case .input = $0.0 { return true }; return false }.count
    }
    var lastInputEpoch: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return values.last { if case .input = $0.0 { return true }; return false }?.1
    }
}

private final class TLSClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aom.test.tls-client")
    private let lock = NSLock()
    private var isReady = false, didFail = false, didClose = false
    private var frames: [ReverseFrame] = []
    private var parser = ReverseFrameParser()
    private let connection: NWConnection
    private let rejectedPin: Completion
    init(port: UInt16, fingerprint: String) {
        let rejectedPin = Completion(); self.rejectedPin = rejectedPin
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first else {
                complete(false); return
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
            let matches = digest == fingerprint
            if !matches { rejectedPin.finish() }
            complete(matches)
        }, queue)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.lock(); self.isReady = true; self.lock.unlock(); self.receive()
            // Network.framework can place a failed TLS path into .waiting
            // instead of terminal .failed. The separate verify result proves
            // this test reached and rejected the actual certificate pin.
            case .failed, .cancelled, .waiting: self.lock.lock(); self.didFail = true; self.lock.unlock()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return didFail }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return didClose || didFail }
    var certificateRejected: Bool { rejectedPin.done }
    func ready() async throws { try await until { self.lock.lock(); defer { self.lock.unlock() }; return self.isReady } }
    func stop() { connection.cancel() }
    func send(_ object: [String: Any]) throws {
        connection.send(content: try ReverseFrame.json(object).encoded(), completion: .contentProcessed { _ in })
    }
    func contains(type: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return frames.contains { (try? $0.object()["type"] as? String) == type }
    }
    func object(type: String) async throws -> [String: Any] {
        try await until { self.contains(type: type) }
        return try take(type: type).object()
    }
    private func take(type: String) -> ReverseFrame {
        lock.lock(); defer { lock.unlock() }
        return frames.remove(at: frames.firstIndex { (try? $0.object()["type"] as? String) == type }!)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, let received = try? self.parser.append(data) {
                self.lock.lock(); self.frames += received; self.lock.unlock()
            }
            if complete || error != nil { self.lock.lock(); self.didClose = true; self.lock.unlock() }
            if !complete && error == nil { self.receive() }
        }
    }
}

@available(macOS 15.0, *) private actor LoopbackIdentity {
    static let shared = LoopbackIdentity()
    private var cached: TransportIdentity?
    func get() async throws -> TransportIdentity {
        if let cached { return cached }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aom-isolated-tls-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("test.key"), cert = directory.appendingPathComponent("test.crt"), p12 = directory.appendingPathComponent("test.p12")
        let processes = ProcessSupervisor(); defer { processes.shutdown() }
        let create = try await processes.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=AndroidOnMac isolated test", "-keyout", key.path, "-out", cert.path], timeout: 10)
        guard create.exitCode == 0 else { throw LoopbackError.openssl }
        let export = try await processes.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:test-fixture-only"], timeout: 10)
        guard export.exitCode == 0 else { throw LoopbackError.openssl }
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test-fixture-only", kSecImportToMemoryOnly as String: true]
        guard SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &imported) == errSecSuccess,
              let raw = (imported as? [[String: Any]])?.first?[kSecImportItemIdentity as String] else { throw LoopbackError.identity }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw LoopbackError.identity }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let result = TransportIdentity(identity: identity, fingerprint: fingerprint); cached = result; return result
    }
}
