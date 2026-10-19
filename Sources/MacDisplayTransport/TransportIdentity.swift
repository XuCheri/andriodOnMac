import Foundation
import Security
import CryptoKit
import AndroidOnMacCore

public enum TransportFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum SecureStore {
    static let service = "chat.xucheri.AndroidOnMac.reverse"
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TransportFailure.message("无法读取钥匙串中的连接身份（\(status)）。") }
        return item as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else {
                throw TransportFailure.message("无法在钥匙串保存连接身份。")
            }
        } else if status != errSecSuccess { throw TransportFailure.message("更新连接身份失败（\(status)）。") }
    }
}

public struct TransportIdentity: @unchecked Sendable {
    let identity: SecIdentity
    public let fingerprint: String

    public static func load(processes: ProcessSupervisor) async throws -> Self {
        try await load(processes: processes, read: SecureStore.read,
                       write: { try SecureStore.write($0, account: $1) })
    }

    // Dependency injection keeps cancellation tests entirely outside the real Keychain.
    static func load(processes: ProcessSupervisor, read: @escaping (String) throws -> Data?,
                     write: @escaping (Data, String) throws -> Void, securityTimeout: TimeInterval = 45) async throws -> Self {
        if let stored = try await TransportSecurityWork.run(timeout: securityTimeout, { checkActive in
            try readStoredIdentity(read: read, checkActive: checkActive)
        }) { return stored }
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aom-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let password = randomSecret()
        let pass = temporary.appendingPathComponent("password")
        try Data(password.utf8).write(to: pass, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pass.path)
        let key = temporary.appendingPathComponent("identity.key")
        let cert = temporary.appendingPathComponent("identity.crt")
        let p12 = temporary.appendingPathComponent("identity.p12")
        let result = try await processes.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
                        "-subj", "/CN=AndroidOnMac", "-keyout", key.path, "-out", cert.path], timeout: 30)
        guard result.exitCode == 0 else { throw TransportFailure.message("创建本机加密身份失败。") }
        try Task.checkCancellation()
        let exported = try await processes.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path,
                        "-passout", "file:" + pass.path], timeout: 15)
        guard exported.exitCode == 0 else { throw TransportFailure.message("导出本机加密身份失败。") }
        try Task.checkCancellation()
        let data = try Data(contentsOf: p12)
        return try await TransportSecurityWork.run(timeout: securityTimeout) { checkActive in
            // Another session may have completed first while OpenSSL ran. Never
            // replace that identity, or turn partial/denied reads into creation.
            if let stored = try readStoredIdentity(read: read, checkActive: checkActive) { return stored }
            try checkActive()
            let identity = try importIdentity(data, password: password)
            try checkActive()
            // Once the first write has entered the system, complete this initial
            // pair together. Cancelling the waiter cannot roll back SecItem calls.
            try write(Data(password.utf8), "tls-password")
            try write(data, "tls-pkcs12")
            return identity
        }
    }

    private static func readStoredIdentity(read: (String) throws -> Data?, checkActive: () throws -> Void) throws -> Self? {
        try checkActive()
        let data = try read("tls-pkcs12")
        try checkActive()
        let pass = try read("tls-password")
        try checkActive()
        if data == nil && pass == nil { return nil }
        guard let data, let pass, let password = String(data: pass, encoding: .utf8), !password.isEmpty else {
            throw TransportFailure.message("钥匙串中的原有连接身份不完整，已保留现有记录，未创建替代身份。请检查钥匙串授权或恢复原有身份。")
        }
        let identity = try importIdentity(data, password: password)
        try checkActive()
        return identity
    }

    private static func importIdentity(_ data: Data, password: String) throws -> Self {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]],
              let raw = list.first?[kSecImportItemIdentity as String] else {
            throw TransportFailure.message("本机加密身份无法载入（\(status)），请检查钥匙串。")
        }
        let identity = raw as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw TransportFailure.message("无法读取连接证书。")
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
        return Self(identity: identity, fingerprint: digest.map { String(format: "%02x", $0) }.joined())
    }
}

func randomSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        // SystemRandomNumberGenerator is also backed by the system CSPRNG.
        return (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
    }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

struct TrustedReceiver: Codable {
    let id: String
    let name: String
    let token: String
}
