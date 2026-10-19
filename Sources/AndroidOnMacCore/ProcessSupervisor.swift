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

/// Owns only processes launched by this instance. Never searches for or kills external processes.
public final class ProcessSupervisor {
    private let lock = NSLock()
    private var children: [UUID: ManagedChild] = [:]

    public init() {}

    @discardableResult
    public func launch(
        executable: URL, arguments: [String], environment: [String: String] = [:],
        input: String? = nil, timeout: TimeInterval? = nil,
        output: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<ProcessResult, Error>) -> Void
    ) throws -> ManagedChild {
        let id = UUID()
        let child = ManagedChild(executable: executable, arguments: arguments, environment: environment,
                                 input: input, output: output) { [weak self] result in
            if let self {
                self.lock.lock()
                self.children.removeValue(forKey: id)
                self.lock.unlock()
            }
            completion(result)
        }
        lock.lock()
        children[id] = child
        lock.unlock()
        do { try child.start(timeout: timeout) }
        catch {
            lock.lock(); children.removeValue(forKey: id); lock.unlock()
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
    private let input: String?
    private let output: (String) -> Void
    private let completion: (Result<ProcessResult, Error>) -> Void
    private let captureLimit = 128 * 1024

    fileprivate init(executable: URL, arguments: [String], environment: [String: String],
                     input: String?, output: @escaping (String) -> Void,
                     completion: @escaping (Result<ProcessResult, Error>) -> Void) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        self.input = input
        self.output = output
        self.completion = completion
    }

    fileprivate func start(timeout: TimeInterval?) throws {
        try process.run()
        let readers = DispatchGroup()
        for (pipe, isError) in [(outputPipe, false), (errorPipe, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { readers.leave() }
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    lock.lock()
                    if isError { err.append(data); if err.count > captureLimit { err = err.suffix(captureLimit) } }
                    else { out.append(data); if out.count > captureLimit { out = out.suffix(captureLimit) } }
                    lock.unlock()
                    output(String(decoding: data, as: UTF8.self))
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            if let input { try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            try? inputPipe.fileHandleForWriting.close()
        }
        if let timeout {
            let work = DispatchWorkItem { [weak self] in self?.stop(reason: .timedOut) }
            lock.lock(); timeoutWork = work; lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            process.waitUntilExit()
            readers.wait()
            lock.lock()
            finished = true
            timeoutWork?.cancel()
            let reason = stopReason
            let result = ProcessResult(exitCode: process.terminationStatus,
                                       stdout: String(decoding: out, as: UTF8.self),
                                       stderr: String(decoding: err, as: UTF8.self))
            lock.unlock()
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            completion(reason.map { .failure($0) } ?? .success(result))
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
