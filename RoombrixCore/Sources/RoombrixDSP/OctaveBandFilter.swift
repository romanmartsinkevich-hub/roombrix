import Foundation

/// Standard acoustic analysis bands and band filtering.
public enum OctaveBand {

    /// Octave-band center frequencies used for decay analysis (Hz).
    /// 63 Hz is included but flagged low-confidence with internal mics.
    public static let standardCenters: [Double] = [63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000]

    /// The subset the Room Score decay subscore is computed over (per brief:
    /// 125 Hz – 4 kHz).
    public static let scoringCenters: [Double] = [125, 250, 500, 1_000, 2_000, 4_000]

    /// Third-octave centers (base-10 preferred values), 50 Hz – 10 kHz.
    public static let thirdOctaveCenters: [Double] = [
        50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
        1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000,
    ]

    /// Bandpass cascade approximating a 4th-order Butterworth octave filter:
    /// two RBJ bandpass sections at the band edges. Adequate for T20/T30
    /// estimation (validated against synthetic decays in the test suite);
    /// swap for an IEC 61260 class-1 design if the REW diff harness demands it.
    public static func filter(center: Double, fraction: Double = 1.0, sampleRate: Double) -> BiquadCascade {
        precondition(center > 0 && center < sampleRate / 2)
        // Fractional-octave bandwidth: f_hi/f_lo = 2^fraction.
        let halfSpan = pow(2.0, fraction / 2)
        let fLow = center / halfSpan
        let fHigh = min(center * halfSpan, sampleRate / 2 * 0.95)
        let q = center / (fHigh - fLow)
        var cascade = BiquadCascade(sections: [
            Biquad.bandpass(center: fLow * 1.02, q: q, sampleRate: sampleRate),
            Biquad.bandpass(center: fHigh * 0.98, q: q, sampleRate: sampleRate),
        ])
        // Normalize to unity gain at the band center.
        let gain = cascade.magnitude(at: center, sampleRate: sampleRate)
        if gain > 0 {
            cascade.sections[0].b0 /= gain
            cascade.sections[0].b1 /= gain
            cascade.sections[0].b2 /= gain
        }
        return cascade
    }

    /// Band-filter a signal (zero-phase, so decays are not smeared forward).
    public static func filtered(
        _ signal: [Double],
        center: Double,
        fraction: Double = 1.0,
        sampleRate: Double
    ) -> [Double] {
        filter(center: center, fraction: fraction, sampleRate: sampleRate)
            .processZeroPhase(signal)
    }
}
