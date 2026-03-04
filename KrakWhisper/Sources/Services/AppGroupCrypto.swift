#if os(iOS)
import CryptoKit
import Foundation

/// Shared AES-GCM encryption for App Group data between main app and keyboard extension.
/// Both targets must include this file.
enum AppGroupCrypto {
    // Deterministic key derived from a shared secret.
    // In production, derive from Keychain for better security.
    private static var key: SymmetricKey {
        let keyData = "com.krakwhisper.shared.v1".data(using: .utf8)!
        let hash = SHA256.hash(data: keyData)
        return SymmetricKey(data: hash)
    }

    /// Encrypt data using AES-GCM.
    static func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    /// Decrypt AES-GCM encrypted data.
    static func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    enum CryptoError: Error {
        case sealFailed
    }
}
#endif
