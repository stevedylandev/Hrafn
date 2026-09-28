import Foundation

/// Knobs for the randomized tests.
///
/// Every pull request runs them at their base counts. The nightly CI job sets
/// `HRAFN_FUZZ_SCALE` (a multiplier) for a longer run, and a failure there
/// prints the seed: `HRAFN_FUZZ_SEED=<seed>` replays the same inputs.
public enum Fuzz {
    public static func iterations(_ base: Int) -> Int {
        let scale = ProcessInfo.processInfo.environment["HRAFN_FUZZ_SCALE"].flatMap(Int.init) ?? 1
        return base * max(1, scale)
    }

    /// A generator seeded from `HRAFN_FUZZ_SEED`, or randomly. The seed is
    /// printed so a failing run can be repeated.
    public static func generator(_ test: String = #function) -> SeededGenerator {
        let seed = ProcessInfo.processInfo.environment["HRAFN_FUZZ_SEED"].flatMap(UInt64.init)
            ?? UInt64.random(in: .min ... .max)
        print("fuzz \(test): HRAFN_FUZZ_SEED=\(seed)")
        return SeededGenerator(seed: seed)
    }
}

/// SplitMix64: small, fast, and reproducible from one 64-bit seed.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
