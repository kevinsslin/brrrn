import Foundation

/// Default avatars for pit members. Every client derives the same emoji from
/// the same handle (stable FNV-1a hash, not Swift's randomized `hashValue`),
/// so a crew sees consistent faces with zero backend support. A user-picked
/// avatar synced through the hub can override this later.
public enum MemberAvatar {
    /// Curated, visually distinct set. Order matters: changing it reshuffles
    /// everyone's face, so append only.
    static let pool = [
        "🔥", "🦊", "🐙", "🦖", "🐺", "🦉", "🐸", "🦁",
        "🐯", "🐼", "🦄", "🐲", "🦅", "🐳", "🦜", "🐝",
        "🦂", "🐍", "🦈", "🐢", "🦩", "🦔", "🐌", "🦚",
    ]

    public static func emoji(for handle: String) -> String {
        pool[Int(fnv1a(handle) % UInt64(pool.count))]
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
