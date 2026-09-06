import Foundation
import RoombrixDSP

/// Magnitude-response analysis: fractional-octave smoothing, spatial
/// averaging over multiple mic positions, and a smoothness metric.
public enum FrequencyResponse {

    public struct Curve: Sendable {
        /// Log-spaced evaluation frequencies, Hz.
        public let frequencies: [Double]
        /// Levels in dB (relative — absolute SPL is not trusted on phone mics).
        public let levelsDB: [Double]

        public init(frequencies: [Double], levelsDB: [Double]) {
            precondition(frequencies.count == levelsDB.count)
            self.frequencies = frequencies
            self.levelsDB = levelsDB
        }
    }

    /// Magnitude response of an IR, evaluated on a log-frequency grid with
    /// fractional-octave (default 1/3) smoothing.
    public static func smoothedMagnitude(
        of ir: ImpulseResponse,
        fraction: Double = 3,
        minFrequency: Double = 20,
        maxFrequency: Double = 20_000,
        pointsPerOctave: Int = 12
    ) -> Curve {
        let spectrum = FFT.magnitudeSpectrum(of: ir.samples)
        let binWidth = ir.sampleRate / Double(2 * (spectrum.count - 1))
        let fMax = min(maxFrequency, ir.sampleRate / 2 * 0.97)

        var frequencies: [Double] = []
        var levels: [Double] = []
        let octaves = log2(fMax / minFrequency)
        let steps = Int(octaves * Double(pointsPerOctave))
        for s in 0...steps {
            let f = minFrequency * pow(2, Double(s) / Double(pointsPerOctave))
            guard f <= fMax else { break }
            // Average power inside the fractional-octave window around f.
            let lo = f / pow(2, 0.5 / fraction)
            let hi = f * pow(2, 0.5 / fraction)
            let loBin = max(1, Int(lo / binWidth))
            let hiBin = min(spectrum.count - 1, max(loBin, Int(hi / binWidth)))
            var power = 0.0
            for b in loBin...hiBin { power += spectrum[b] * spectrum[b] }
            power /= Double(hiBin - loBin + 1)
            frequencies.append(f)
            levels.append(10 * log10(max(power, 1e-20)))
        }

        // Normalize to the mean level so curves are comparable across gains.
        let mean = levels.reduce(0, +) / Double(max(levels.count, 1))
        return Curve(frequencies: frequencies, levelsDB: levels.map { $0 - mean })
    }

    /// Power-average several position measurements into one curve
    /// (the multi-point wizard output). Curves must share a frequency grid.
    public static func spatialAverage(_ curves: [Curve]) -> Curve? {
        guard let first = curves.first else { return nil }
        guard curves.allSatisfy({ $0.frequencies.count == first.frequencies.count }) else { return nil }
        var averaged = [Double](repeating: 0, count: first.levelsDB.count)
        for curve in curves {
            for (i, level) in curve.levelsDB.enumerated() {
                averaged[i] += pow(10, level / 10)
            }
        }
        let n = Double(curves.count)
        return Curve(
            frequencies: first.frequencies,
            levelsDB: averaged.map { 10 * log10($0 / n) }
        )
    }

    /// Smoothness metric: psychoacoustically weighted standard deviation (dB)
    /// of the smoothed curve. Mid frequencies (300 Hz – 6 kHz) get full weight;
    /// the extremes are down-weighted where phone mics and modal effects
    /// dominate. Lower is smoother.
    public static func smoothnessDeviation(
        of curve: Curve,
        minFrequency: Double = 100,
        maxFrequency: Double = 12_000
    ) -> Double {
        var weightedSum = 0.0
        var weightTotal = 0.0
        var pairs: [(level: Double, weight: Double)] = []
        for (f, level) in zip(curve.frequencies, curve.levelsDB) {
            guard f >= minFrequency, f <= maxFrequency else { continue }
            let weight: Double
            switch f {
            case ..<300: weight = 0.5
            case ..<6_000: weight = 1.0
            default: weight = 0.6
            }
            pairs.append((level, weight))
            weightedSum += level * weight
            weightTotal += weight
        }
        guard weightTotal > 0 else { return 0 }
        let mean = weightedSum / weightTotal
        var variance = 0.0
        for (level, weight) in pairs {
            variance += weight * (level - mean) * (level - mean)
        }
        return (variance / weightTotal).squareRoot()
    }

    /// Prominent low-frequency peaks in the curve — candidates for matching
    /// against geometrically predicted room modes.
    /// Returns (frequency, prominence dB) pairs below `maxFrequency`.
    public static func lowFrequencyPeaks(
        in curve: Curve,
        maxFrequency: Double = 300,
        minProminenceDB: Double = 5
    ) -> [(frequency: Double, prominenceDB: Double)] {
        var peaks: [(Double, Double)] = []
        let levels = curve.levelsDB
        for i in 1..<(levels.count - 1) {
            let f = curve.frequencies[i]
            guard f <= maxFrequency else { break }
            guard levels[i] > levels[i - 1], levels[i] >= levels[i + 1] else { continue }
            // Prominence: height above the higher of the two flanking minima
            // within ±1/2 octave.
            var leftMin = levels[i]
            var j = i - 1
            while j >= 0 && curve.frequencies[j] > f / 1.414 {
                leftMin = min(leftMin, levels[j])
                j -= 1
            }
            var rightMin = levels[i]
            j = i + 1
            while j < levels.count && curve.frequencies[j] < f * 1.414 {
                rightMin = min(rightMin, levels[j])
                j += 1
            }
            let prominence = levels[i] - max(leftMin, rightMin)
            if prominence >= minProminenceDB {
                peaks.append((f, prominence))
            }
        }
        return peaks
    }
}
