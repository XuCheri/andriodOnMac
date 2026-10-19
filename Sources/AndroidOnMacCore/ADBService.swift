import Foundation
import Darwin

public struct EnginePaths {
    public let directory: URL
    public var adb: URL { directory.appendingPathComponent("adb") }
    public var scrcpy: URL { directory.appendingPathComponent("scrcpy") }
    public var server: URL { directory.appendingPathComponent("scrcpy-server") }
    public var environment: [String: String] {
        ["ADB": adb.path, "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5037",
         "ANDROID_ADB_SERVER_ADDRESS": "127.0.0.1", "ANDROID_ADB_SERVER_PORT": "5037",
         "SCRCPY_SERVER_PATH": server.path,
         "SCRCPY_ICON_PATH": directory.appendingPathComponent("icon.png").path]
    }
    public init(directory: URL) { self.directory = directory }
    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: adb.path)
        && FileManager.default.isExecutableFile(atPath: scrcpy.path)
        && FileManager.default.fileExists(atPath: server.path)
    }
    public static func locate() -> EnginePaths? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["ANDROIDONMAC_ENGINE_DIR"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("engine"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cache/engine"))
        return candidates.map(EnginePaths.init).first { $0.isAvailable }
    }
}

public enum ADBFailure: LocalizedError {
    case unavailable(String)
    case incompatibleServer(Int)
    case occupiedPort
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "内置连接引擎不可用：\(detail)"
        case .incompatibleServer(let version):
            return "已有 ADB 服务版本不兼容（协议 \(version)）。请先在原应用中结束连接，再重试；本应用不会停止它。"
        case .occupiedPort: return "本机 5037 端口被其他服务占用或 ADB 无响应。请检查现有 Android 开发工具。"
        case .failed(let detail): return detail
        }
    }
}

/// Checks the existing server without invoking adb, which could otherwise kill an incompatible server.
public enum ADBServerProbe {
    public static func version(port: UInt16 = 5037) throws -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBFailure.occupiedPort }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            if errno == ECONNREFUSED { return nil }
            throw ADBFailure.occupiedPort
        }
        let request = Array("000chost:version".utf8)
        guard request.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == request.count,
              try read(fd, count: 4) == "OKAY",
              let size = Int(try read(fd, count: 4), radix: 16), size > 0, size <= 16,
              let version = Int(try read(fd, count: size), radix: 16)
        else { throw ADBFailure.occupiedPort }
        return version
    }
    private static func read(_ fd: Int32, count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeMutableBytes {
                recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard n > 0 else { throw ADBFailure.occupiedPort }
            offset += n
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public actor ADBService {
    public let paths: EnginePaths
    private let processes: ProcessSupervisor
    private var server: ManagedChild?
    private var ensuringServer = false

    public init(paths: EnginePaths, processes: ProcessSupervisor) {
        self.paths = paths; self.processes = processes
    }

    public func ensureServer() async throws {
        while ensuringServer {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        ensuringServer = true
        defer { ensuringServer = false }
        // The pinned engine's adb reports Android Debug Bridge version 1.0.41.
        if let version = try ADBServerProbe.version() {
            guard version == 41 else { throw ADBFailure.incompatibleServer(version) }
            return
        }
        try Task.checkCancellation()
        server = try processes.launch(executable: paths.adb,
            arguments: ["-L", "tcp:127.0.0.1:5037", "server", "nodaemon"],
            environment: paths.environment, completion: { _ in })
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let version = try ADBServerProbe.version() {
                guard version == 41 else { throw ADBFailure.incompatibleServer(version) }
                return
            }
            if server?.isRunning == false { break }
        }
        throw ADBFailure.failed("ADB 服务未能启动，请查看是否有其他 Android 工具占用连接。")
    }

    private func execute(_ args: [String], input: String? = nil, timeout: TimeInterval = 12) async throws -> ProcessResult {
        try await ensureServer()
        let result = try await processes.run(executable: paths.adb, arguments: args,
                                             environment: paths.environment, input: input, timeout: timeout)
        guard result.exitCode == 0 else {
            throw ADBFailure.failed(Self.friendlyError(result.combined))
        }
        return result
    }

    public func devices() async throws -> [AndroidDevice] {
        ADBParser.devices(try await execute(["devices", "-l"]).stdout)
    }

    public func discover() async throws -> [MDNSService] {
        ADBParser.mdns(try await execute(["mdns", "services"], timeout: 5).stdout)
    }

    public func pair(endpoint: WirelessEndpoint, code: String) async throws {
        guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ADBFailure.failed("请输入手机上显示的 6 位配对码。")
        }
        // stdin keeps the pairing code out of process arguments and diagnostic logs.
        let result = try await execute(["pair", endpoint.address], input: code + "\n", timeout: 20)
        guard result.combined.lowercased().contains("successfully paired") else {
            throw ADBFailure.failed("配对失败。请保持手机配对页面打开，并核对配对端口及新的配对码。")
        }
    }

    public func connect(endpoint: WirelessEndpoint) async throws {
        let result = try await execute(["connect", endpoint.address], timeout: 15)
        let text = result.combined.lowercased()
        guard (text.contains("connected to") || text.contains("already connected")),
              !text.contains("failed"), !text.contains("cannot"), !text.contains("unable") else {
            throw ADBFailure.failed("连接失败。请使用无线调试主页面的连接端口，并确认 Mac 与手机处于同一 Wi-Fi。")
        }
    }

    public func key(serial: String, code: Int) async throws {
        guard [3, 4, 26, 187, 224, 223].contains(code) else { return }
        _ = try await execute(["-s", serial, "shell", "input", "keyevent", String(code)])
    }

    public static func friendlyError(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("unauthorized") { return "手机尚未授权。请解锁手机并允许这台 Mac 的 USB 调试。" }
        if text.contains("offline") { return "设备离线。请检查数据线或重新开启手机无线调试。" }
        if text.contains("refused") || text.contains("unreachable") || text.contains("timed out") {
            return "无法连接到手机。请检查同一 Wi-Fi、IP 地址和当前连接端口。"
        }
        if text.contains("pair") || text.contains("authentication") {
            return "无线配对未成功。请重新打开配对页面，核对配对端口和配对码。"
        }
        if text.contains("no devices") || text.contains("not found") { return "没有找到设备。请连接手机并允许调试。" }
        return "ADB 操作失败。请检查手机授权与连接状态，然后重试。"
    }
}
