import Foundation

/// Early-to-late energy ratios from the impulse response.
public enum Clarity {

    /// C_te = 10 log10( early energy [0, te] / late energy (te, ∞) ), dB,
    /// measured from the direct-sound arrival.
    public static func clarity(_ ir: ImpulseResponse, earlyTime: Double) -> Double? {
        let causal = ir.causalPart
        let boundary = Int(earlyTime * ir.sampleRate)
        guard boundary > 0, boundary < causal.count else { return nil }
        var early = 0.0
        var late = 0.0
        for (i, v) in causal.enumerated() {
            if i <= boundary { early += v * v } else { late += v * v }
        }
        guard late > 0 else { return nil }
        return 10 * log10(early / late)
    }

    /// C50 — speech clarity (50 ms boundary).
    public static func c50(_ ir: ImpulseResponse) -> Double? {
        clarity(ir, earlyTime: 0.05)
    }

    /// C80 — music clarity (80 ms boundary). Target for listening rooms: > 0 dB.
    public static func c80(_ ir: ImpulseResponse) -> Double? {
        clarity(ir, earlyTime: 0.08)
    }

    /// D50 — definition, early energy fraction in [0, 1].
    public static func d50(_ ir: ImpulseResponse) -> Double? {
        let causal = ir.causalPart
        let boundary = Int(0.05 * ir.sampleRate)
        guard boundary > 0, boundary < causal.count else { return nil }
        var early = 0.0
        var total = 0.0
        for (i, v) in causal.enumerated() {
            total += v * v
            if i <= boundary { early += v * v }
        }
        guard total > 0 else { return nil }
        return early / total
    }
}
