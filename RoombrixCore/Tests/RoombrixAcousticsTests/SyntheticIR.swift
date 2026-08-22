import Foundation
@testable import RoombrixAcoustics
@testable import RoombrixDSP

/// Synthetic impulse-response generators with exact ground truth
/// (brief §8: test the DSP kernel against synthetic rooms).
enum SyntheticIR {

    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEF : seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// White noise shaped by an exponential energy decay with exact RT60.
    /// Amplitude envelope: 10^(−3 t / RT60) → energy decays 60 dB in RT60 s.
    static func exponentialDecay(
        rt60: Double,
        duration: Double,
        sampleRate: Double,
        noiseFloorDB: Double? = nil,
        seed: UInt64 = 42
    ) -> ImpulseResponse {
        var rng = SeededGenerator(seed: seed)
        let count = Int(duration * sampleRate)
        var samples = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = pow(10, -3 * t / rt60)
            samples[i] = Double.random(in: -1...1, using: &rng) * envelope
        }
        if let noiseFloorDB {
            let amplitude = pow(10, noiseFloorDB / 20)
            for i in 0..<count {
                samples[i] += Double.random(in: -1...1, using: &rng) * amplitude
            }
        }
        return ImpulseResponse(samples: samples, sampleRate: sampleRate, directIndex: 0)
    }

    /// Different decay per octave band: noise is band-filtered first, each
    /// band gets its own exponential envelope, and bands are summed.
    static func bandDependentDecay(
        bandRT60: [Double: Double],  // center frequency → RT60
        duration: Double,
        sampleRate: Double,
        seed: UInt64 = 42
    ) -> ImpulseResponse {
        var rng = SeededGenerator(seed: seed)
        let count = Int(duration * sampleRate)
        let noise = (0..<count).map { _ in Double.random(in: -1...1, using: &rng) }
        var sum = [Double](repeating: 0, count: count)
        for (center, rt) in bandRT60 {
            let banded = OctaveBand.filtered(noise, center: center, sampleRate: sampleRate)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                sum[i] += banded[i] * pow(10, -3 * t / rt)
            }
        }
        return ImpulseResponse(samples: sum, sampleRate: sampleRate, directIndex: 0)
    }

    /// Direct sound plus a decaying periodic spike train (flutter echo) and a
    /// low-level diffuse tail.
    static func flutter(
        period: Double,
        duration: Double,
        sampleRate: Double,
        seed: UInt64 = 42
    ) -> ImpulseResponse {
        var rng = SeededGenerator(seed: seed)
        let count = Int(duration * sampleRate)
        var samples = [Double](repeating: 0, count: count)
        samples[0] = 1
        // Diffuse decay well below the spikes.
        for i in 0..<count {
            let t = Double(i) / sampleRate
            samples[i] += Double.random(in: -1...1, using: &rng) * 0.02 * pow(10, -3 * t / 0.4)
        }
        // Spikes every `period` seconds, decaying slowly.
        var k = 1
        while true {
            let index = Int(Double(k) * period * sampleRate)
            guard index < count else { break }
            samples[index] += 0.5 * pow(0.85, Double(k))
            k += 1
        }
        return ImpulseResponse(samples: samples, sampleRate: sampleRate, directIndex: 0)
    }

    /// Decaying sinusoid (an isolated room mode) over a faster broadband decay.
    static func modalIR(
        modeFrequency: Double,
        modeRT60: Double,
        broadbandRT60: Double,
        duration: Double,
        sampleRate: Double,
        seed: UInt64 = 42
    ) -> ImpulseResponse {
        var rng = SeededGenerator(seed: seed)
        let count = Int(duration * sampleRate)
        var samples = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            samples[i] = Double.random(in: -1...1, using: &rng) * 0.3 * pow(10, -3 * t / broadbandRT60)
            samples[i] += sin(2 * .pi * modeFrequency * t) * pow(10, -3 * t / modeRT60)
        }
        return ImpulseResponse(samples: samples, sampleRate: sampleRate, directIndex: 0)
    }
}
