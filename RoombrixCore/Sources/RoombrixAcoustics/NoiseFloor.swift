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
    /// to ambient RMS, dB. Used by the live level-setting meter only.
    public static func signalToNoiseDB(signal: [Double], ambient: [Double]) -> Double? {
        guard let noise = estimate(ambient: ambient), !signal.isEmpty else { return nil }
        var sum = 0.0
        for v in signal { sum += v * v }
        let rms = (sum / Double(signal.count)).squareRoot()
        return 20 * log10(max(rms, 1e-10)) - noise.levelDBFS
    }

    /// The headline SNR figure for a measurement: peak-to-noise gap.
    /// Peak of the whole recording vs the RMS of a quiet window ending
    /// 0.3 s before the marker.
    ///
    /// The previous headline (sweep-region RMS − ambient RMS) understated a
    /// 58.6 dB peak-to-noise gap as "25 dB": the 10 s sweep's RMS averages
    /// its band-by-band journey through the loudspeaker's response and sits
    /// far below peak, so the number never matched how references (REW)
    /// characterize a capture.
    public static func peakToNoiseGapDB(
        recording: [Double],
        markerStartIndex: Int,
        sampleRate: Double
    ) -> Double? {
        let quietEnd = markerStartIndex - Int(0.3 * sampleRate)
        let quietStart = max(0, quietEnd - Int(1.0 * sampleRate))
        guard quietEnd - quietStart >= Int(0.3 * sampleRate) else { return nil }
        var energy = 0.0
        for i in quietStart..<quietEnd { energy += recording[i] * recording[i] }
        let noiseRMS = (energy / Double(quietEnd - quietStart)).squareRoot()
        let peak = recording.lazy.map(abs).max() ?? 0
        guard peak > 0, noiseRMS > 0 else { return nil }
        return 20 * log10(peak / noiseRMS)
    }
}
