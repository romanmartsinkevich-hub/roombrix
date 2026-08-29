import Foundation

/// Schroeder backward integration: turns a (band-filtered) impulse response
/// into an energy decay curve (EDC), the input to all RT estimates.
public enum SchroederIntegration {

    public struct DecayCurve: Sendable {
        /// EDC in dB relative to total energy (starts at 0, decreases).
        public let levelsDB: [Double]
        public let sampleRate: Double
        /// Estimated noise floor relative to total energy, dB.
        public let noiseFloorDB: Double
        /// Index at which integration was truncated (noise-crossing point).
        public let truncationIndex: Int
        /// Decay range available for fitting, on the EDC scale where the
        /// T20/T30 fits happen: distance from the EDC top to the noise
        /// plateau an untruncated integration would flatten at (analytic:
        /// noise power × remaining samples / total energy), minus a 10 dB
        /// safety margin per ISO 3382-2 practice. Drives adaptive metric
        /// selection: a T30 fit ending at −35 dB is only trustworthy when
        /// the plateau sits well below it — e.g. a −43 dB plateau leaves
        /// 8 dB of margin and a usable range of 33 dB → T20 territory.
        public let usableRangeDB: Double
    }

    /// Compute the EDC with noise-floor truncation.
    ///
    /// Integrating a full noisy tail biases RT long, so we estimate the noise
    /// level from the final segment of the squared response and truncate the
    /// integration where the smoothed decay meets noise + margin (a simplified
    /// Lundeby procedure — adequate for v1, revisit against the REW harness).
    public static func decayCurve(
        of samples: [Double],
        sampleRate: Double,
        noiseMarginDB: Double = 8
    ) -> DecayCurve {
        precondition(!samples.isEmpty)
        let squared = samples.map { $0 * $0 }
        let totalEnergy = squared.reduce(0, +)
        guard totalEnergy > 0 else {
            return DecayCurve(
                levelsDB: [Double](repeating: -120, count: samples.count),
                sampleRate: sampleRate,
                noiseFloorDB: -120,
                truncationIndex: samples.count,
                usableRangeDB: 0
            )
        }

        // Noise estimate from the last 10 % of the response.
        let tailStart = max(0, squared.count - squared.count / 10)
        let tail = squared[tailStart...]
        let noisePower = tail.reduce(0, +) / Double(max(tail.count, 1))
        let meanPower = totalEnergy / Double(squared.count)
        let noiseFloorDB = 10 * log10(max(noisePower / meanPower, 1e-14))

        // Smoothed level in 10 ms blocks to find the noise-crossing point.
        // The scan starts after the energy peak (direct sound): a recording
        // with a silent lead-in would otherwise truncate before the decay
        // even begins.
        var peakIndex = 0
        var peakValue = 0.0
        for (i, v) in squared.enumerated() where v > peakValue {
            peakValue = v
            peakIndex = i
        }
        let block = max(1, Int(0.01 * sampleRate))
        var truncationIndex = squared.count
        var i = (peakIndex / block + 1) * block
        while i + block <= squared.count {
            let blockPower = squared[i..<(i + block)].reduce(0, +) / Double(block)
            let blockDB = 10 * log10(max(blockPower / meanPower, 1e-14))
            if blockDB <= noiseFloorDB + noiseMarginDB {
                truncationIndex = i
                break
            }
            i += block
        }

        // Backward integration up to the truncation point.
        var edc = [Double](repeating: -120, count: squared.count)
        var running = 0.0
        for j in stride(from: truncationIndex - 1, through: 0, by: -1) {
            running += squared[j]
            edc[j] = running
        }
        let reference = edc[0]
        for j in 0..<truncationIndex {
            edc[j] = 10 * log10(max(edc[j] / reference, 1e-14))
        }

        // Usable range: −(untruncated-EDC noise plateau) − 10 dB safety.
        // The plateau is computed analytically (noise power × samples past
        // the truncation point) so it does not depend on how much noisy tail
        // happens to be in the recording.
        let remainingNoiseEnergy = noisePower * Double(squared.count - truncationIndex)
        let usableRangeDB: Double
        if remainingNoiseEnergy > 0 {
            let plateauDB = 10 * log10(max(remainingNoiseEnergy / totalEnergy, 1e-14))
            usableRangeDB = max(0, min(90, -plateauDB - 10))
        } else {
            usableRangeDB = 90
        }

        return DecayCurve(
            levelsDB: edc,
            sampleRate: sampleRate,
            noiseFloorDB: noiseFloorDB,
            truncationIndex: truncationIndex,
            usableRangeDB: usableRangeDB
        )
    }
}
