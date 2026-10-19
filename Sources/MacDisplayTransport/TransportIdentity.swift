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
        if let data = try SecureStore.read("tls-pkcs12"), let pass = try SecureStore.read("tls-password"),
           let password = String(data: pass, encoding: .utf8) {
            return try importIdentity(data, password: password)
        }
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
        let exported = try await processes.run(executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path,
                        "-passout", "file:" + pass.path], timeout: 15)
        guard exported.exitCode == 0 else { throw TransportFailure.message("导出本机加密身份失败。") }
        let data = try Data(contentsOf: p12)
        let identity = try importIdentity(data, password: password)
        try SecureStore.write(Data(password.utf8), account: "tls-password")
        try SecureStore.write(data, account: "tls-pkcs12")
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
