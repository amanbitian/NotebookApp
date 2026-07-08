import CryptoKit
import Foundation

/// SHA-256 over serialized bytes. Serves triple duty per §5 note 5: journal change
/// detection, thumbnail cache key, and sync-state comparison.
enum ContentHash {
    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
