import Foundation

/// Sabine-model absorption accounting: predicted RT, required added
/// absorption to reach a target, and per-band coefficient handling.
public enum Absorption {

    /// Octave bands used for absorption bookkeeping (Hz).
    public static let bands: [Double] = [125, 250, 500, 1_000, 2_000, 4_000]

    /// Absorption coefficients per band for a material/treatment
    /// (ISO 354-style random-incidence values).
    public struct Coefficients: Sendable, Codable {
        /// One value per entry of `Absorption.bands`.
        public let values: [Double]

        public init(values: [Double]) {
            precondition(values.count == Absorption.bands.count)
            self.values = values
        }

        public func value(at band: Double) -> Double {
            guard let index = Absorption.bands.firstIndex(of: band) else { return 0 }
            return values[index]
        }
    }

    /// Sabine RT60 = 0.161 · V / A, per band.
    public static func sabineRT60(volume: Double, absorptionSabins: Double) -> Double {
        precondition(volume > 0)
        guard absorptionSabins > 0 else { return .infinity }
        return 0.161 * volume / absorptionSabins
    }

    /// Total absorption (metric sabins) implied by a measured RT60.
    public static func impliedAbsorption(volume: Double, rt60: Double) -> Double {
        precondition(volume > 0 && rt60 > 0)
        return 0.161 * volume / rt60
    }

    /// Added sabins needed to bring a band from `measuredRT60` to `targetRT60`.
    /// Returns 0 when the room is already at or below target.
    public static func requiredAddedSabins(
        volume: Double,
        measuredRT60: Double,
        targetRT60: Double
    ) -> Double {
        guard measuredRT60 > targetRT60, targetRT60 > 0 else { return 0 }
        let current = impliedAbsorption(volume: volume, rt60: measuredRT60)
        let needed = impliedAbsorption(volume: volume, rt60: targetRT60)
        return needed - current
    }

    /// Square meters of a treatment (with coefficient α at the band) needed
    /// to supply `sabins` of absorption. Returns nil when the material is
    /// ineffective (α below a practical floor) at that band — the caller must
    /// then prescribe a different treatment class, never "more of the same".
    public static func requiredArea(
        sabins: Double,
        coefficient: Double,
        minimumUsefulCoefficient: Double = 0.2
    ) -> Double? {
        guard coefficient >= minimumUsefulCoefficient else { return nil }
        return sabins / coefficient
    }

    /// Porous-absorber physics: an absorber is effective down to roughly the
    /// frequency whose quarter wavelength matches its depth (mounted on a
    /// rigid wall, no air gap). This is the "honesty rule" the recommendation
    /// engine enforces — thin panels cannot fix bass.
    public static func lowestEffectiveFrequency(absorberDepth: Double) -> Double {
        precondition(absorberDepth > 0)
        return 343.0 / (4 * absorberDepth)
    }
}
