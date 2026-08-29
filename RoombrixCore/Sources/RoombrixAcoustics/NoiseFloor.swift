import Foundation

/// Background-noise estimation.
///
/// With phone mics there is no absolute SPL trust, so this is informational
/// (5 % score weight) and always labeled an estimate in the UI.
public enum NoiseFloor {

    public struct Estimate: Sendable {
        /// RMS level of the ambient recording relative to digital full scale, dB.
        public let levelDBFS: Double
        /// Rough NC-style descriptor for plain-language output.
        public let descriptor: String

        public init(levelDBFS: Double, descriptor: String) {
            self.levelDBFS = levelDBFS
            self.descriptor = descriptor
        }
    }

    /// Estimate from an ambient (pre-stimulus) recording segment.
    public static func estimate(ambient: [Double]) -> Estimate? {
        guard !ambient.isEmpty else { return nil }
        var sum = 0.0
        for v in ambient { sum += v * v }
        let rms = (sum / Double(ambient.count)).squareRoot()
        let dbfs = 20 * log10(max(rms, 1e-10))
        let descriptor: String
        switch dbfs {
        case ..<(-70): descriptor = "very quiet"
        case ..<(-55): descriptor = "quiet"
        case ..<(-40): descriptor = "moderate"
        default: descriptor = "noisy"
        }
        return Estimate(levelDBFS: dbfs, descriptor: descriptor)
    }

    /// Signal-to-noise check before a measurement: ratio of stimulus-band RMS
    /// to ambient RMS, dB. The capture flow requires ~40 dB+ for a clean
    /// T30; below that the app asks the user to raise the volume.
    public static func signalToNoiseDB(signal: [Double], ambient: [Double]) -> Double? {
        guard let noise = estimate(ambient: ambient), !signal.isEmpty else { return nil }
        var sum = 0.0
        for v in signal { sum += v * v }
        let rms = (sum / Double(signal.count)).squareRoot()
        return 20 * log10(max(rms, 1e-10)) - noise.levelDBFS
    }
}
