import Foundation
import Network
import Security
import Darwin
import AndroidOnMacCore

public enum DisplayServerEvent {
    case pairing(UUID, String)
    case pairingCancelled(UUID)
    case receiverReady(String)
    case input([String: Any])
    case firstFrame
    case statistics(Int, Int)
    case requestKeyFrame
    case congestion
    case disconnected
    case stopped
    case failure(String)
}

/// All listener, authentication and send state is confined to `queue`.
public final class DisplayServer: @unchecked Sendable {
    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var parser = ReverseFrameParser()
        var role: String?
        var hello: [String: Any]?
        var lastActivity = ProcessInfo.processInfo.systemUptime
        var pendingFrames = 0
        var pendingBytes = 0
        var pendingWrites = 0
        var closing = false
        var messageRate = DisplayMessageRateLimit()
        var inputWindowStart = ProcessInfo.processInfo.systemUptime
        var inputCount = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "chat.xucheri.AndroidOnMac.display-server", qos: .userInteractive)
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var control: Peer?
    private var media: Peer?
    private var pendingPair: Peer?
    private var trusted: [TrustedReceiver] = []
    private var activeReceiver: TrustedReceiver?
    private var sessionID = ""
    private var bootstrapToken = randomSecret()
    private var bootstrapDeadline: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var running = false
    private var needsKeyFrame = true
    private var lastCongestion: TimeInterval = 0
    private var hasRenderedFrame = false
    private let connectionState = DisplayConnectionState()
    private var startAttempted = false
    private var startID: UUID?
    private var startContinuation: CheckedContinuation<(port: UInt16, token: String), Error>?
    private var event: (DisplayServerEvent, UInt64) -> Void = { _, _ in }
    private let readTrust: () throws -> Data?
    private let saveTrust: (Data) throws -> Void

    /// Snapshot only: callers must check it again when consuming an event on
    /// another queue, and pass the captured value into every media send.
    public var connectionGeneration: UInt64 { connectionState.generation }

    public init() {
        readTrust = { try SecureStore.read("trusted-receivers") }
        saveTrust = { try SecureStore.write($0, account: "trusted-receivers") }
    }

    // Tests supply an isolated store; production always uses the Keychain.
    init(readTrust: @escaping () throws -> Data?, saveTrust: @escaping (Data) throws -> Void) {
        self.readTrust = readTrust; self.saveTrust = saveTrust
    }

    public func start(identity: TransportIdentity, lan: Bool,
                      onEvent: @escaping (DisplayServerEvent, UInt64) -> Void) async throws -> (port: UInt16, token: String) {
        let attempt = UUID()
        let cancellation = DisplayConnectionState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.startAttempted else {
                        continuation.resume(throwing: TransportFailure.message("每个接收服务只能启动一次，请创建新会话。")); return
                    }
                    self.startAttempted = true; self.startID = attempt
                    self.startContinuation = continuation
                    guard !self.connectionState.isStopped, !cancellation.isStopped else {
                        self.stopOnQueue(); return
                    }
                    do {
                        self.event = onEvent
                        if let data = try self.readTrust() {
                            self.trusted = try JSONDecoder().decode([TrustedReceiver].self, from: data)
                        }
                        guard !self.connectionState.isStopped, !cancellation.isStopped else { throw CancellationError() }
                        let tls = NWProtocolTLS.Options()
                        guard let secIdentity = sec_identity_create(identity.identity) else { throw TransportFailure.message("TLS 身份不可用。") }
                        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
                        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
                        let parameters = NWParameters(tls: tls, tcp: tcp)
                        parameters.includePeerToPeer = false
                        if !lan { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
                        let listener = try NWListener(using: parameters, on: .any)
                        self.listener = listener
                        if lan {
                            listener.service = NWListener.Service(
                                name: "AndroidOnMac · " + (Host.current().localizedName ?? "Mac"),
                                type: "_aom-display._tcp", txtRecord: Self.discoveryRecord(fingerprint: identity.fingerprint))
                        }
                        listener.stateUpdateHandler = { [weak self, weak listener] state in
                            guard let self, let listener, self.listener === listener else { return }
                            switch state {
                            case .ready:
                                guard self.startContinuation != nil, let port = listener.port else { return }
                                guard !self.connectionState.isStopped else { self.stopOnQueue(); return }
                                self.running = true
                                self.bootstrapDeadline = ProcessInfo.processInfo.systemUptime + 300
                                self.startTimer()
                                self.finishStart(.success((port.rawValue, self.bootstrapToken)))
                            case .failed(let error):
                                let wasRunning = self.running
                                self.finishStart(.failure(error)); self.stopOnQueue()
                                if wasRunning { self.emit(.failure("接收服务已停止，请检查本地网络权限。")) }
                            case .cancelled: self.stopOnQueue()
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                    } catch { self.finishStart(.failure(error)); self.stopOnQueue() }
                }
            }
        } onCancel: {
            cancellation.stop()
            self.queue.async {
                // Cancelling a rejected second start must not stop the first.
                if self.startID == attempt { self.stopOnQueue() }
            }
        }
    }

    private func finishStart(_ result: Result<(port: UInt16, token: String), Error>) {
        let continuation = startContinuation; startContinuation = nil
        continuation?.resume(with: result)
    }

    private func emit(_ value: DisplayServerEvent) {
        switch value {
        case .stopped, .failure: event(value, connectionGeneration)
        default:
            // Atomically snapshot stop + epoch. A concurrent public stop must
            // not label an old input callback with the new stopped epoch.
            if let epoch = connectionState.activeGeneration { event(value, epoch) }
        }
    }

    public func approve(_ id: UUID) {
        queue.async {
            guard self.running, !self.connectionState.isStopped, let peer = self.pendingPair, peer.id == id, let hello = peer.hello,
                  let deviceID = hello["deviceID"] as? String else { return }
            do {
                let receiver = TrustedReceiver(id: deviceID, name: String((hello["deviceName"] as? String ?? "Android").prefix(80)), token: randomSecret())
                var updated = self.trusted.filter { $0.id != deviceID }; updated.append(receiver)
                try self.saveTrust(JSONEncoder().encode(updated))
                self.trusted = updated // Commit trust only after durable storage succeeds.
                self.bootstrapToken = randomSecret() // the visible QR has now been consumed
                self.pendingPair = nil
                self.authenticateControl(peer, receiver: receiver)
            } catch {
                self.rejectOnQueue(peer, "无法保存手机身份，请检查 Mac 钥匙串。")
                self.emit(.failure("无法保存手机身份，请检查 Mac 钥匙串。"))
            }
        }
    }

    public func reject(_ id: UUID) {
        queue.async {
            guard let peer = self.pendingPair, peer.id == id else { return }
            self.pendingPair = nil; self.rejectOnQueue(peer, "Mac 拒绝了本次配对。")
        }
    }

    public func send(_ frame: ReverseFrame, generation: UInt64) {
        let bytes = frame.payload.count + 14
        guard connectionState.reserve(bytes: bytes, generation: generation) else {
            if frame.kind == .video, connectionState.markCongestion(generation: generation) {
                queue.async {
                    self.connectionState.clearCongestion()
                    guard self.running, generation == self.connectionGeneration else { return }
                    self.reportCongestion()
                }
            }
            return
        }
        queue.async {
            defer { self.connectionState.release(bytes: bytes) }
            guard self.running, generation == self.connectionGeneration, let peer = self.media else { return }
            if frame.kind == .video {
                if self.needsKeyFrame && !frame.keyFrame { return }
                if peer.pendingFrames >= 3 || peer.pendingBytes > 1024 * 1024 {
                    self.reportCongestion(); return
                }
                if frame.keyFrame { self.needsKeyFrame = false }
            } else if frame.kind == .audio, peer.pendingBytes > 1024 * 1024 { return }
            if !self.write(frame, to: peer) {
                if frame.kind == .video { self.reportCongestion() }
                else if frame.kind == .json { self.remove(peer) }
            }
        }
    }

    public func sendControl(_ object: [String: Any], generation: UInt64) {
        guard let frame = try? ReverseFrame.json(object) else { return }
        let bytes = frame.payload.count + 14
        guard connectionState.reserve(bytes: bytes, generation: generation) else { return }
        queue.async {
            defer { self.connectionState.release(bytes: bytes) }
            guard self.running, generation == self.connectionGeneration, let peer = self.control else { return }
            self.write(frame, to: peer)
        }
    }

    private func reportCongestion() {
        needsKeyFrame = true
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCongestion > 1 { lastCongestion = now; emit(.congestion) }
    }

    public func stop() {
        connectionState.stop() // Invalidate queued UI/capture work immediately.
        queue.async { self.stopOnQueue() }
    }

    private func accept(_ connection: NWConnection) {
        guard running, !connectionState.isStopped, peers.count < 6 else { connection.cancel(); return }
        // Never accept non-local address families or internet peers.
        guard case .hostPort(let host, _) = connection.endpoint,
              Self.isLocalAddress(String(describing: host)) else { connection.cancel(); return }
        let peer = Peer(connection); peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: self.read(peer)
            case .failed, .cancelled: self.remove(peer)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func read(_ peer: Peer) {
        guard running, !peer.closing, peers[peer.id] != nil else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, self.running, !self.connectionState.isStopped,
                  !peer.closing, self.peers[peer.id] != nil else { return }
            do {
                if let data {
                    for frame in try peer.parser.append(data) {
                        guard peer.messageRate.accept(now: ProcessInfo.processInfo.systemUptime, authenticated: peer.role != nil) else {
                            self.rejectOnQueue(peer, "接收端请求过于频繁，请重新连接。"); return
                        }
                        guard frame.kind == .json else { throw ReverseProtocolError.invalidKind }
                        try self.handle(frame.object(), from: peer)
                        if peer.closing || self.peers[peer.id] == nil { return }
                    }
                }
                if complete || error != nil { self.remove(peer) }
                else { self.read(peer) }
            } catch {
                let message = (error as? ReverseProtocolError) == .unsupportedVersion
                    ? "连接协议版本不兼容，请更新两端应用。" : "接收端发送了无效连接数据。"
                self.rejectOnQueue(peer, message)
            }
        }
    }

    private func handle(_ object: [String: Any], from peer: Peer) throws {
        if peer.role == nil {
            guard pendingPair !== peer else { return }
            try ReverseValidation.validateHello(object)
            let deviceID = object["deviceID"] as! String
            let channel = object["channel"] as! String
            if channel == "control" {
                guard control == nil, pendingPair == nil else { rejectOnQueue(peer, "已有手机连接，请先停止当前会话。"); return }
                if let token = object["authToken"] as? String,
                   let known = trusted.first(where: { $0.id == deviceID && ReverseValidation.equalSecret($0.token, token) }) {
                    if let active = activeReceiver, active.id != known.id {
                        rejectOnQueue(peer, "此会话只允许原手机重连。"); return
                    }
                    authenticateControl(peer, receiver: known)
                } else if activeReceiver == nil, let token = object["pairToken"] as? String,
                          ProcessInfo.processInfo.systemUptime <= bootstrapDeadline,
                          ReverseValidation.equalSecret(token, bootstrapToken) {
                    pendingPair = peer; peer.hello = object
                    emit(.pairing(peer.id, String((object["deviceName"] as? String ?? "Android").prefix(80))))
                } else { rejectOnQueue(peer, "配对已失效，请在 Mac 重新开始并扫码连接。") }
            } else {
                guard media == nil, control != nil, let active = activeReceiver, active.id == deviceID,
                      object["sessionID"] as? String == sessionID,
                      let token = object["authToken"] as? String,
                      ReverseValidation.equalSecret(active.token, token) else {
                    rejectOnQueue(peer, "画面连接身份不匹配。"); return
                }
                peer.role = "media"; media = peer; peer.lastActivity = ProcessInfo.processInfo.systemUptime
                needsKeyFrame = true
                emit(.receiverReady(active.name))
            }
            return
        }
        guard peer === control else { throw ReverseProtocolError.invalidJSON }
        peer.lastActivity = ProcessInfo.processInfo.systemUptime
        switch object["type"] as? String {
        case "ping": writeJSON(["type": "pong"], to: peer)
        case "pong": break
        case "firstFrame":
            guard media != nil, !hasRenderedFrame else { return }
            hasRenderedFrame = true; emit(.firstFrame)
        case "requestKeyFrame":
            guard media != nil else { return }; needsKeyFrame = true; emit(.requestKeyFrame)
        case "stats":
            if let frames = ReverseValidation.integer(object["frames"]), let depth = ReverseValidation.integer(object["queueDepth"]),
               frames >= 0, depth >= 0, depth <= 10000 { emit(.statistics(frames, depth)) }
        case "input":
            let now = ProcessInfo.processInfo.systemUptime
            if now - peer.inputWindowStart >= 1 { peer.inputCount = 0; peer.inputWindowStart = now }
            peer.inputCount += 1
            guard media != nil, hasRenderedFrame, peer.inputCount <= 300, ReverseValidation.validateInput(object) else { return }
            emit(.input(object))
        case "stop": stopOnQueue(); emit(.stopped)
        default: throw ReverseProtocolError.invalidJSON
        }
    }

    private func authenticateControl(_ peer: Peer, receiver: TrustedReceiver) {
        guard !peer.closing, peers[peer.id] != nil, !connectionState.isStopped else { return }
        connectionState.advance(); hasRenderedFrame = false
        activeReceiver = receiver; control = peer; peer.role = "control"
        peer.lastActivity = ProcessInfo.processInfo.systemUptime
        sessionID = UUID().uuidString
        writeJSON(["type": "paired", "authToken": receiver.token, "sessionID": sessionID], to: peer)
    }

    private func writeJSON(_ object: [String: Any], to peer: Peer) {
        if let frame = try? ReverseFrame.json(object) { write(frame, to: peer) }
    }

    @discardableResult private func write(_ frame: ReverseFrame, to peer: Peer) -> Bool {
        guard !peer.closing, peers[peer.id] != nil, let data = try? frame.encoded() else { return false }
        let limit = peer === media ? ReverseFrame.maximumBody + 4 : 256 * 1024
        guard peer.pendingWrites < 128, data.count <= limit - peer.pendingBytes else {
            // Media may drop; a control queue that cannot keep up must close so
            // commands are never replayed seconds later against a new display.
            if peer !== media { remove(peer) }
            return false
        }
        let video = frame.kind == .video
        if video { peer.pendingFrames += 1 }
        peer.pendingWrites += 1; peer.pendingBytes += data.count
        peer.connection.send(content: data, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer, self.peers[peer.id] != nil else { return }
            if video { peer.pendingFrames = max(0, peer.pendingFrames - 1) }
            peer.pendingWrites = max(0, peer.pendingWrites - 1)
            peer.pendingBytes = max(0, peer.pendingBytes - data.count)
            if error != nil { self.remove(peer) }
        })
        return true
    }

    private func rejectOnQueue(_ peer: Peer, _ reason: String) {
        guard !peer.closing, peers[peer.id] != nil else { return }
        writeJSON(["type": "error", "message": reason], to: peer)
        peer.closing = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self, weak peer] in
            if let peer { self?.remove(peer) }
        }
    }

    private func remove(_ peer: Peer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        peer.connection.stateUpdateHandler = nil; peer.connection.cancel()
        if pendingPair === peer { pendingPair = nil; emit(.pairingCancelled(peer.id)) }
        let wasActive = control === peer || media === peer
        if wasActive {
            let others = [control, media].compactMap { $0 }.filter { $0 !== peer }
            connectionState.advance(); hasRenderedFrame = false
            control = nil; media = nil; needsKeyFrame = true
            for other in others { peers.removeValue(forKey: other.id); other.connection.stateUpdateHandler = nil; other.connection.cancel() }
            if running { emit(.disconnected) }
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for peer in Array(self.peers.values) {
                let deadline: Double = peer === self.pendingPair ? 120 : (peer.role == nil ? 10 : 8)
                if peer.role != "media", now - peer.lastActivity > deadline { self.remove(peer) }
            }
            if let peer = self.control { self.writeJSON(["type": "ping"], to: peer) }
        }
        self.timer = timer; timer.resume()
    }

    private func stopOnQueue() {
        connectionState.stop()
        finishStart(.failure(CancellationError()))
        running = false; timer?.cancel(); timer = nil
        let stoppingControl = control
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        let connections = Array(peers.values); peers.removeAll()
        for peer in connections {
            peer.closing = true; peer.connection.stateUpdateHandler = nil
            if peer !== stoppingControl { peer.connection.cancel() }
        }
        if let connection = stoppingControl?.connection,
           let terminal = try? ReverseFrame.json(["type": "stopped"]).encoded() {
            // The epoch is already invalid and reads are disabled. Give the
            // terminal message a bounded opportunity to suppress phone retry.
            connection.send(content: terminal, completion: .contentProcessed { _ in connection.cancel() })
            queue.asyncAfter(deadline: .now() + 0.15) { connection.cancel() }
        } else { stoppingControl?.connection.cancel() }
        control = nil; media = nil; pendingPair = nil; activeReceiver = nil
        hasRenderedFrame = false; sessionID = ""
    }

    public static func isLocalAddress(_ value: String) -> Bool {
        let components = value.split(separator: "%", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count), !components.contains(where: { $0.isEmpty }) else { return false }
        let address = String(components[0])
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            guard components.count == 1 else { return false }
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return bytes[0] == 127 || bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        return (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }

    static func discoveryRecord(fingerprint: String) -> Data {
        // Public discovery metadata only. Pairing and authentication secrets
        // must never be advertised through Bonjour.
        NetService.data(fromTXTRecord: ["fingerprint": Data(fingerprint.utf8), "v": Data("1".utf8)])
    }

    public static func localIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var values: [(String, String)] = []
        var current = pointer
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if isLocalAddress(value) { values.append((name, value)) }
            }
        }
        return values.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// Small synchronized admission gate: frame buffers cannot accumulate without
/// bound before reaching the server's serial queue. The same lock publishes the
/// connection epoch to UI and capture queues without synchronous queue hops.
final class DisplayConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var stopped = false
    private var pendingBytes = 0
    private var pendingCount = 0
    private var congestionQueued = false
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    var activeGeneration: UInt64? { lock.lock(); defer { lock.unlock() }; return stopped ? nil : epoch }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func advance() { lock.lock(); defer { lock.unlock() }; epoch &+= 1 }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stopped = true; epoch &+= 1 }
    }
    func reserve(bytes: Int, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, generation == epoch, bytes >= 0, pendingCount < 16,
              bytes <= ReverseFrame.maximumBody + 4 - pendingBytes else { return false }
        pendingCount += 1; pendingBytes += bytes; return true
    }
    func release(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        pendingCount = max(0, pendingCount - 1); pendingBytes = max(0, pendingBytes - bytes)
    }
    func markCongestion(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, generation == epoch, !congestionQueued else { return false }
        congestionQueued = true; return true
    }
    func clearCongestion() { lock.lock(); congestionQueued = false; lock.unlock() }
}

struct DisplayMessageRateLimit {
    private var start: TimeInterval = 0
    private var count = 0
    mutating func accept(now: TimeInterval, authenticated: Bool) -> Bool {
        if now - start >= 1 { start = now; count = 0 }
        count += 1
        return count <= (authenticated ? 600 : 20)
    }
}
