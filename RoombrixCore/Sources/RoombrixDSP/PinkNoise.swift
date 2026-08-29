import Foundation

/// Pink-noise generator for the level-setting pass.
///
/// The user loops this file through their playback system while the app
/// shows live per-band headroom against the measured ambient floor. Pink
/// noise (−3 dB/octave) puts equal energy in every octave band, so one
/// broadband level check covers the whole analysis range.
public enum PinkNoise {

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B9 : seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Generate loop-clean pink noise.
    ///
    /// - Pinking filter: Paul Kellet's refined economy method (white noise
    ///   through a fixed 3-pole approximation of −3 dB/octave, accurate to
    ///   within ±0.05 dB over the audio band at 44.1/48 kHz).
    /// - Loop cleanliness: the final `crossfade` seconds are overlap-added
    ///   into the beginning, so the wrap point is continuous when the file
    ///   is looped.
    ///
    /// - Parameters:
    ///   - duration: seconds (30–60 s recommended for level setting).
    ///   - peakLevelDBFS: output is peak-normalized to this level.
    public static func generate(
        duration: Double,
        sampleRate: Double,
        peakLevelDBFS: Double = -6,
        crossfade: Double = 0.5,
        seed: UInt64 = 20_260_829
    ) -> [Double] {
        precondition(duration > 2 * crossfade && sampleRate > 0)
        var rng = SeededGenerator(seed: seed)
        let count = Int(duration * sampleRate)
        let fadeCount = Int(crossfade * sampleRate)

        // Generate slightly long so the tail can be folded into the head.
        var raw = [Double](repeating: 0, count: count + fadeCount)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for i in 0..<raw.count {
            let white = Double.random(in: -1...1, using: &rng)
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            raw[i] = b0 + b1 + b2 + white * 0.1848
        }

        // Fold the excess tail into the head with an equal-power crossfade
        // so sample `count-1` flows seamlessly into sample 0 when looping.
        var samples = Array(raw[0..<count])
        for i in 0..<fadeCount {
            let t = Double(i) / Double(fadeCount)
            let fadeIn = sin(t * .pi / 2)
            let fadeOut = cos(t * .pi / 2)
            samples[i] = samples[i] * fadeIn + raw[count + i] * fadeOut
        }

        // Peak-normalize to the target level.
        let peak = samples.map(abs).max() ?? 1
        let gain = pow(10, peakLevelDBFS / 20) / max(peak, 1e-12)
        return samples.map { $0 * gain }
    }
}
