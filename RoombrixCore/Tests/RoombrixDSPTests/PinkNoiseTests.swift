import XCTest
@testable import RoombrixDSP

final class PinkNoiseTests: XCTestCase {

    func bandRMSdB(_ signal: [Double], center: Double, sampleRate: Double) -> Double {
        let banded = OctaveBand.filtered(signal, center: center, sampleRate: sampleRate)
        // Skip filter transients at the edges.
        let core = banded[banded.count / 8 ..< banded.count * 7 / 8]
        let power = core.reduce(0) { $0 + $1 * $1 } / Double(core.count)
        return 10 * log10(max(power, 1e-20))
    }

    func testSpectrumIsPink() {
        let fs = 48_000.0
        let noise = PinkNoise.generate(duration: 10, sampleRate: fs)

        // Pink noise: equal energy per OCTAVE band (our octave filterbank has
        // constant relative bandwidth, so band levels should be flat).
        let levels = [250.0, 500, 1_000, 2_000, 4_000].map {
            bandRMSdB(noise, center: $0, sampleRate: fs)
        }
        for (i, level) in levels.enumerated().dropFirst() {
            XCTAssertEqual(level, levels[i - 1], accuracy: 1.5,
                           "octave-band levels should be flat for pink noise")
        }
    }

    func testPeakLevel() {
        let noise = PinkNoise.generate(duration: 5, sampleRate: 48_000, peakLevelDBFS: -6)
        let peak = noise.map(abs).max()!
        XCTAssertEqual(20 * log10(peak), -6, accuracy: 0.1)
    }

    func testLoopsCleanly() {
        let fs = 48_000.0
        let noise = PinkNoise.generate(duration: 5, sampleRate: fs)
        // Loop junction: the sample-to-sample step across the wrap point must
        // be comparable to ordinary in-signal steps (no click).
        var maxStep = 0.0
        for i in 1..<noise.count {
            maxStep = max(maxStep, abs(noise[i] - noise[i - 1]))
        }
        let wrapStep = abs(noise[0] - noise[noise.count - 1])
        XCTAssertLessThanOrEqual(wrapStep, maxStep,
                                 "wrap-point discontinuity must not exceed ordinary signal steps")
    }

    func testDeterministicForSameSeed() {
        let a = PinkNoise.generate(duration: 2, sampleRate: 48_000, seed: 7)
        let b = PinkNoise.generate(duration: 2, sampleRate: 48_000, seed: 7)
        XCTAssertEqual(a, b)
    }
}
