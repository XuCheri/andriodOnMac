import Foundation
import Darwin

public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var combined: String { stdout + "\n" + stderr }
}

public enum ProcessFailure: LocalizedError {
    case timedOut
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .timedOut: return "操作超时，请检查手机和连接状态。"
        case .cancelled: return "操作已取消。"
        }
    }
}

public enum ProcessOutputMode {
    case pipe
    /// Give stdout a terminal so native stdio flushes each log line. Stdin stays
    /// on its own pipe, and stderr stays separate; no input is echoed into logs.
    case lineBufferedTerminal
}

/// Owns only processes launched by this instance. Never searches for or kills external processes.
public final class ProcessSupervisor {
    private let lock = NSLock()
    private var children: [UUID: ManagedChild] = [:]
    private var closed = false

    public init() {}

    @discardableResult
    public func launch(
        executable: URL, arguments: [String], environment: [String: String] = [:],
        input: String? = nil, timeout: TimeInterval? = nil,
        outputMode: ProcessOutputMode = .pipe,
        output: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<ProcessResult, Error>) -> Void
    ) throws -> ManagedChild {
        let id = UUID()
        let child = ManagedChild(executable: executable, arguments: arguments, environment: environment,
                                 input: input, outputMode: outputMode, output: output) { [weak self] result in
            if let self {
                self.lock.lock()
                self.children.removeValue(forKey: id)
                self.lock.unlock()
            }
            completion(result)
        }
        lock.lock()
        guard !closed else { lock.unlock(); throw ProcessFailure.cancelled }
        children[id] = child
        do {
            try child.start(timeout: timeout)
            lock.unlock()
        }
        catch {
            children.removeValue(forKey: id); lock.unlock()
            throw error
        }
        return child
    }

    public func run(executable: URL, arguments: [String], environment: [String: String] = [:],
                    input: String? = nil, timeout: TimeInterval = 12) async throws -> ProcessResult {
        let cancellation = CancellationBox()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    let child = try launch(executable: executable, arguments: arguments,
                                           environment: environment, input: input, timeout: timeout) {
                        continuation.resume(with: $0)
                    }
                    cancellation.set(child)
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { cancellation.cancel() })
    }

    public func terminateAll() {
        lock.lock(); let owned = Array(children.values); lock.unlock()
        owned.forEach { $0.stop() }
    }

    /// Permanently closes the owner, including work resuming after an await during app termination.
    public func shutdown() {
        lock.lock(); closed = true; let owned = Array(children.values); lock.unlock()
        owned.forEach { $0.stop() }
    }

    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }; return children.count
    }
}

private final class CancellationBox {
    private let lock = NSLock()
    private var cancelled = false
    private var child: ManagedChild?
    func set(_ child: ManagedChild) {
        lock.lock(); self.child = child; let stop = cancelled; lock.unlock()
        if stop { child.stop() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let child = child; lock.unlock()
        child?.stop()
    }
}

public final class ManagedChild {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputPipe = Pipe()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var stopReason: ProcessFailure?
    private var finished = false
    private var timeoutWork: DispatchWorkItem?
    private var pipeDeadline: TimeInterval?
    private let requestedExecutable: URL
    private let outputMode: ProcessOutputMode
    private let input: String?
    private let output: (String) -> Void
    private let completion: (Result<ProcessResult, Error>) -> Void
    private let captureLimit = 128 * 1024

    fileprivate init(executable: URL, arguments: [String], environment: [String: String],
                     input: String?, outputMode: ProcessOutputMode, output: @escaping (String) -> Void,
                     completion: @escaping (Result<ProcessResult, Error>) -> Void) {
        requestedExecutable = executable
        let mergedEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        if let launcher = Self.launcher(environment: mergedEnvironment) {
            process.executableURL = launcher
            process.arguments = [executable.path] + arguments
        } else {
            // A development install may omit the helper. This fallback owns only
            // the direct child; pipe draining is still bounded after it exits.
            process.executableURL = executable
            process.arguments = arguments
        }
        process.environment = mergedEnvironment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        self.input = input
        self.outputMode = outputMode
        self.output = output
        self.completion = completion
    }

    fileprivate func start(timeout: TimeInterval?) throws {
        // Preserve Process.run's launch-failure semantics when using the helper.
        guard FileManager.default.isExecutableFile(atPath: requestedExecutable.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                          userInfo: [NSFilePathErrorKey: requestedExecutable.path])
        }
        let terminal: (reader: FileHandle, writer: FileHandle)?
        if case .lineBufferedTerminal = outputMode { terminal = try Self.makeOutputTerminal() }
        else { terminal = nil }
        if let terminal { process.standardOutput = terminal.writer }
        do { try process.run() }
        catch {
            try? terminal?.reader.close()
            try? terminal?.writer.close()
            throw error
        }
        // FileHandle-backed descriptors are not automatically closed in the
        // launching parent. Leave the terminal slave solely with the child.
        try? terminal?.writer.close()
        let readers = DispatchGroup()
        for (handle, isError) in [(terminal?.reader ?? outputPipe.fileHandleForReading, false),
                                 (errorPipe.fileHandleForReading, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { try? handle.close(); readers.leave() }
                read(handle.fileDescriptor, isError: isError)
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? inputPipe.fileHandleForWriting.close() }
            if let input { writeInput(Data(input.utf8)) }
        }
        if let timeout {
            let work = DispatchWorkItem { [weak self] in self?.stop(reason: .timedOut) }
            lock.lock(); timeoutWork = work; lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            process.waitUntilExit()
            // An inherited writer may survive if a helper is unavailable or a
            // subprocess deliberately leaves its process group. Never wait for
            // its EOF indefinitely. poll/read use nonblocking descriptors, and
            // each reader owns closing its own handle (no cross-thread close).
            lock.lock()
            pipeDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            timeoutWork?.cancel()
            lock.unlock()
            readers.wait()
            lock.lock()
            finished = true
            timeoutWork?.cancel()
            let reason = stopReason
            let result = ProcessResult(exitCode: process.terminationStatus,
                                       stdout: String(decoding: out, as: UTF8.self),
                                       stderr: String(decoding: err, as: UTF8.self))
            lock.unlock()
            completion(reason.map { .failure($0) } ?? .success(result))
        }
    }

    private static func makeOutputTerminal() throws -> (reader: FileHandle, writer: FileHandle) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else {
            let code = errno; Darwin.close(master); Darwin.close(slave)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Preserve bytes (no newline-to-CRLF conversion), and explicitly disable
        // echo even though stdin never uses this terminal.
        attributes.c_oflag &= ~tcflag_t(OPOST)
        attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
            let code = errno; Darwin.close(master); Darwin.close(slave)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        return (FileHandle(fileDescriptor: master, closeOnDealloc: true),
                FileHandle(fileDescriptor: slave, closeOnDealloc: true))
    }

    private static func launcher(environment: [String: String]) -> URL? {
        if let override = environment["ANDROIDONMAC_PROCESS_LAUNCHER"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ProcessLauncher")
        if let adjacent, FileManager.default.isExecutableFile(atPath: adjacent.path) { return adjacent }
        // The app bundle must use its signed helper only. This path is solely a
        // SwiftPM development/test convenience, not a packaged-app fallback.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/ProcessLauncher")
            if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        }
        return nil
    }

    private var shouldFinishReading: Bool {
        lock.lock(); defer { lock.unlock() }
        return pipeDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
    }

    private func read(_ descriptor: Int32, isError: Bool) {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while !shouldFinishReading {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            if event.revents & Int16(POLLNVAL) != 0 { break }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                break
            }
            let data = Data(bytes.prefix(count))
            lock.lock()
            if isError { err.append(data); if err.count > captureLimit { err = err.suffix(captureLimit) } }
            else { out.append(data); if out.count > captureLimit { out = out.suffix(captureLimit) } }
            lock.unlock()
            output(String(decoding: data, as: UTF8.self))
        }
    }

    private func writeInput(_ data: Data) {
        let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count && !shouldFinishReading {
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&event, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                guard let base = bytes.baseAddress else { break }
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    break
                }
                offset += count
            }
        }
    }

    public var isRunning: Bool { process.isRunning }

    public func stop() { stop(reason: .cancelled) }

    private func stop(reason: ProcessFailure) {
        lock.lock()
        guard !finished, stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        lock.unlock()
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [self] in
            // Process keeps the PID reserved until it is reaped; never target a name or another process.
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}
