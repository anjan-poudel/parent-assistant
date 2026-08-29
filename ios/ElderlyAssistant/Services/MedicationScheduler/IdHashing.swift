import Foundation
import CryptoKit

/// Truncated SHA-256 hash of a UUID, used to correlate observability events
/// and notification payloads without ever emitting the underlying identifier.
///
/// The first 12 bytes (96 bits) of the digest give ~2^-48 collision probability
/// across ~16M IDs — sufficient for medication / contact correlation and safe
/// to include in logs and pushes.
enum IdHashing {
    static func shortHash(of id: UUID) -> String {
        var uuid = id.uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        let digest = SHA256.hash(data: data)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
