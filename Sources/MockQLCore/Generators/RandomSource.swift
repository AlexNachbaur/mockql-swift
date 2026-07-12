/// A deterministic, seedable random number generator (SplitMix64).
///
/// MockQL derives every generated field value from a seed computed from the server seed, the
/// type name, the record id, and the field name — so generated data is stable for the lifetime
/// of a server *and* reproducible across runs given the same server seed.
public struct RandomSource: RandomNumberGenerator, Sendable {
    private var state: UInt64

    /// Creates a generator with the given seed.
    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Derives a stable seed for one field of one record.
    ///
    /// Uses FNV-1a over the identifying strings so the result is a pure function of its inputs.
    static func stableSeed(serverSeed: UInt64, typeName: String, recordID: String?, fieldName: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0xFF
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(typeName)
        mix(recordID ?? "")
        mix(fieldName)
        return hash ^ serverSeed
    }
}
