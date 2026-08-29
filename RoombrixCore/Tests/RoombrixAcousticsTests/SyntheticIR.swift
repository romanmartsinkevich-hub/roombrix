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

    /// "Hostile" but realistic room IR: silent lead-in (so the direct sound
    /// sits at a nonzero index and peak auto-detection is exercised), a
    /// direct-sound peak, distinct aperiodic early reflections, a diffuse
    /// exponential tail with known RT60, a realistic noise floor across the
    /// whole record, and a small DC offset. The other generators start at
    /// index 0 with no arrival structure; this one stresses the full
    /// pipeline the way a real capture does.
    /// `directGain` scales ONLY the direct spike (not reflections or tail):
    /// the empirically observed excessive-playback failure raises the direct
    /// peak relative to the reverberant field (21 dB → 60 dB in real
    /// captures), and this parameter reproduces exactly that signature.
    static func realisticRoom(
        rt60: Double,
        duration: Double,
        sampleRate: Double,
        leadIn: Double = 0.05,
        noiseFloorDB: Double = -55,
        dcOffset: Double = 0.002,
        directGain: Double = 1.0,
        seed: UInt64 = 42
    ) -> (ir: ImpulseResponse, directIndex: Int) {
        var rng = SeededGenerator(seed: seed)
        let count = Int((leadIn + duration) * sampleRate)
        let directIndex = Int(leadIn * sampleRate)
        var samples = [Double](repeating: 0, count: count)

        // Direct sound: dominant peak with a short bandlimited-ish skirt.
        samples[directIndex] = 1.0 * directGain
        if directIndex + 1 < count { samples[directIndex + 1] = 0.35 * directGain }
        if directIndex > 0 { samples[directIndex - 1] = 0.15 * directGain }

        // Distinct early reflections at aperiodic delays (no flutter).
        let earlyReflections: [(delayMs: Double, gain: Double)] = [
            (2.9, 0.55), (5.3, -0.40), (8.7, 0.30), (13.1, -0.22),
        ]
        for reflection in earlyReflections {
            let index = directIndex + Int(reflection.delayMs / 1_000 * sampleRate)
            if index < count { samples[index] += reflection.gain }
        }

        // Diffuse tail from ~15 ms after the direct sound.
        let tailStart = directIndex + Int(0.015 * sampleRate)
        for i in tailStart..<count {
            let t = Double(i - tailStart) / sampleRate
            samples[i] += Double.random(in: -1...1, using: &rng) * 0.35 * pow(10, -3 * t / rt60)
        }

        // Noise floor over the entire record + DC offset.
        let noiseAmplitude = pow(10, noiseFloorDB / 20)
        for i in 0..<count {
            samples[i] += Double.random(in: -1...1, using: &rng) * noiseAmplitude + dcOffset
        }

        // No explicit directIndex: peak auto-detection must find it.
        return (ImpulseResponse(samples: samples, sampleRate: sampleRate), directIndex)
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
