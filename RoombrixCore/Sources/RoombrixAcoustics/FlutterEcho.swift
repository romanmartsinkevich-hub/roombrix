import Foundation
import RoombrixDSP

/// Flutter-echo detection: periodic energy peaks in the impulse-response tail
/// caused by sound bouncing between parallel reflective surfaces.
public enum FlutterEcho {

    public struct Detection: Sendable {
        /// Repetition period, seconds.
        public let period: Double
        /// Implied spacing of the parallel surfaces, meters (period × c / 2).
        public let surfaceSpacing: Double
        /// Normalized autocorrelation peak (0…1). Higher = more audible flutter.
        public let strength: Double

        public init(period: Double, surfaceSpacing: Double, strength: Double) {
            self.period = period
            self.surfaceSpacing = surfaceSpacing
            self.strength = strength
        }
    }

    static let speedOfSound = 343.0

    /// Autocorrelate the detrended log-energy envelope of the IR tail and
    /// look for a strong periodic peak.
    ///
    /// The exponential decay itself is removed first (linear fit on the dB
    /// envelope); otherwise the decay trend correlates at every lag and any
    /// smooth room would false-positive.
    ///
    /// - Parameters:
    ///   - tailStart: analysis start after the direct sound (default 30 ms,
    ///     past the early-reflection cluster).
    ///   - minSpacing/maxSpacing: plausible parallel-wall distances, meters.
    ///   - threshold: normalized autocorrelation needed to report a detection.
    public static func detect(
        in ir: ImpulseResponse,
        tailStart: Double = 0.03,
        minSpacing: Double = 1.0,
        maxSpacing: Double = 12.0,
        threshold: Double = 0.25
    ) -> Detection? {
        let fs = ir.sampleRate
        let start = ir.directIndex + Int(tailStart * fs)
        guard start < ir.samples.count else { return nil }
        let tail = Array(ir.samples[start...])
        guard tail.count > Int(0.1 * fs) else { return nil }

        // Log-energy envelope in 1 ms blocks (keeps periodicity sharp while
        // suppressing sample-level noise).
        let blockSize = max(1, Int(0.001 * fs))
        var envelope: [Double] = []
        envelope.reserveCapacity(tail.count / blockSize)
        var i = 0
        while i + blockSize <= tail.count {
            var energy = 0.0
            for j in i..<(i + blockSize) { energy += tail[j] * tail[j] }
            envelope.append(10 * log10(max(energy / Double(blockSize), 1e-16)))
            i += blockSize
        }
        guard envelope.count > 16 else { return nil }

        // Restrict analysis to the decaying region above the noise floor.
        // Past the noise crossing the envelope flattens; detrending a bent
        // (decay-then-flat) curve leaves a smooth residual whose
        // autocorrelation is high at small lags — a false-positive machine.
        let tailBlocks = max(1, envelope.count / 10)
        let noiseLevel = envelope.suffix(tailBlocks).reduce(0, +) / Double(tailBlocks)
        if let crossing = envelope.firstIndex(where: { $0 <= noiseLevel + 8 }), crossing > 32 {
            envelope = Array(envelope[..<crossing])
        }
        guard envelope.count > 16 else { return nil }

        // Detrend: remove the linear (exponential-decay) component in dB.
        let n = Double(envelope.count)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for (index, y) in envelope.enumerated() {
            let x = Double(index)
            sumX += x; sumY += y
            sumXY += x * y
            sumXX += x * x
        }
        let denom = n * sumXX - sumX * sumX
        guard denom > 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        let residual = envelope.enumerated().map { $0.element - (slope * Double($0.offset) + intercept) }

        let blockDuration = Double(blockSize) / fs
        let minLag = max(2, Int(2 * minSpacing / speedOfSound / blockDuration))
        let maxLag = min(Int(2 * maxSpacing / speedOfSound / blockDuration), residual.count / 2)
        guard maxLag > minLag else { return nil }

        var zeroLag = 0.0
        for v in residual { zeroLag += v * v }
        guard zeroLag > 0 else { return nil }

        func autocorrelation(at lag: Int) -> Double {
            guard lag > 0, lag < residual.count else { return 0 }
            var acc = 0.0
            for k in 0..<(residual.count - lag) {
                acc += residual[k] * residual[k + lag]
            }
            return acc / zeroLag
        }

        var bestLag = 0
        var bestValue = 0.0
        for lag in minLag...maxLag {
            let normalized = autocorrelation(at: lag)
            if normalized > bestValue {
                bestValue = normalized
                bestLag = lag
            }
        }

        guard bestValue >= threshold, bestLag > 0 else { return nil }
        // The winner must be a genuine peak, not the window edge of a
        // smoothly decaying autocorrelation (another false-positive shape).
        guard bestValue >= autocorrelation(at: bestLag - 1),
              bestValue >= autocorrelation(at: bestLag + 1)
        else { return nil }
        // Require the period's harmonic to also correlate, otherwise a single
        // late reflection would masquerade as flutter.
        let harmonicLag = bestLag * 2
        if harmonicLag < residual.count {
            var acc = 0.0
            for k in 0..<(residual.count - harmonicLag) {
                acc += residual[k] * residual[k + harmonicLag]
            }
            guard acc / zeroLag >= threshold * 0.3 else { return nil }
        }

        let period = Double(bestLag) * blockDuration
        return Detection(
            period: period,
            surfaceSpacing: period * speedOfSound / 2,
            strength: bestValue
        )
    }
}
