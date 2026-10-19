import Foundation

/// Keychain authentication is synchronous and cannot be interrupted safely.
/// Keep it off session queues, and detach the waiter on cancellation/timeout.
/// The system operation may finish later; its result must not revive a session.
enum TransportSecurityWork {
    private static let queue = DispatchQueue(label: "chat.xucheri.AndroidOnMac.transport-security", qos: .userInitiated)
    static let authorizationMessage = "等待系统钥匙串授权超时。请在 macOS 的授权对话框中输入 Mac 登录或钥匙串密码，或取消该对话框后重试；原有连接身份已保留。"

    static func run<Value>(timeout: TimeInterval = 45,
                           _ operation: @escaping (_ checkActive: () throws -> Void) throws -> Value) async throws -> Value {
        let pending = PendingSecurityWork<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                queue.async {
                    guard pending.isPending else { return }
                    do {
                        let value = try operation(pending.checkActive)
                        pending.finish(.success(value))
                    } catch { pending.finish(.failure(error)) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                    pending.finish(.failure(TransportFailure.message(authorizationMessage)))
                }
            }
        } onCancel: { pending.finish(.failure(CancellationError())) }
    }
}

private final class PendingSecurityWork<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    func checkActive() throws { if !isPending { throw CancellationError() } }
    func install(_ value: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func finish(_ value: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: value)
    }
}
