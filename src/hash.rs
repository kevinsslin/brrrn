/// Stable 64-bit FNV-1a for persisted dedup keys. `DefaultHasher` is not a
/// cross-version storage format; the scan cache survives binary upgrades.
pub fn stable_hash(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv_is_stable_and_distinguishes_inputs() {
        assert_eq!(stable_hash(b""), 0xcbf29ce484222325);
        assert_eq!(stable_hash(b"a"), 0xaf63dc4c8601ec8c);
        assert_eq!(stable_hash(b"brrrn"), 0x44480d1dbe5e16e1);
        assert_eq!(stable_hash(b"same"), stable_hash(b"same"));
        assert_ne!(stable_hash(b"same"), stable_hash(b"different"));
    }
}
