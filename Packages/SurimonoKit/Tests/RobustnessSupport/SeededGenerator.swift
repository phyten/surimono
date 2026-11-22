import Foundation

/// SplitMix64: small, fast and the same on every run, so a seed and a case index name one input for good.
package struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    package init(seed: UInt64) { state = seed }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// The seed of one case. Swift's `Hasher` is seeded differently in every process, so a driver and its child
    /// could not agree on it; FNV-1a is stable.
    package static func caseSeed(_ seed: UInt64, _ label: String, _ index: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in Array("\(seed)/\(label)/\(index)".utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
