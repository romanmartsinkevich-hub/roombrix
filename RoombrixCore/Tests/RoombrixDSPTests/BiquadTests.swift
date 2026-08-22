import XCTest
@testable import RoombrixDSP

final class BiquadTests: XCTestCase {

    func sine(frequency: Double, sampleRate: Double, count: Int) -> [Double] {
        (0..<count).map { sin(2 * .pi * frequency * Double($0) / sampleRate) }
    }

    func rms(_ signal: ArraySlice<Double>) -> Double {
        (signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)).squareRoot()
    }

    func testBandpassPassesCenterRejectsFar() {
        let fs = 48_000.0
        let filter = OctaveBand.filter(center: 1_000, sampleRate: fs)

        let inBand = filter.processZeroPhase(sine(frequency: 1_000, sampleRate: fs, count: 9_600))
        let outOfBand = filter.processZeroPhase(sine(frequency: 8_000, sampleRate: fs, count: 9_600))

        // Compare steady-state RMS (skip transient edges).
        let inRMS = rms(inBand[2_400..<7_200])
        let outRMS = rms(outOfBand[2_400..<7_200])
        XCTAssertGreaterThan(inRMS, 0.3, "center frequency largely passes")
        XCTAssertLessThan(outRMS / inRMS, 0.05, "3 octaves away attenuated by 26+ dB")
    }

    func testZeroPhaseFilteringHasNoLag() {
        let fs = 8_000.0
        // Impulse through zero-phase filter: response should be symmetric
        // around the impulse position.
        var impulse = [Double](repeating: 0, count: 2_048)
        impulse[1_024] = 1
        let filter = OctaveBand.filter(center: 500, sampleRate: fs)
        let response = filter.processZeroPhase(impulse)
        let peakIndex = response.enumerated().max { abs($0.element) < abs($1.element) }!.offset
        XCTAssertEqual(peakIndex, 1_024, "zero-phase filtering keeps the energy centroid in place")
    }

    func testLowpassAttenuatesHighFrequencies() {
        let fs = 48_000.0
        let lp = Biquad.lowpass(cutoff: 1_000, sampleRate: fs)
        let low = lp.process(sine(frequency: 100, sampleRate: fs, count: 9_600))
        let high = lp.process(sine(frequency: 10_000, sampleRate: fs, count: 9_600))
        XCTAssertGreaterThan(rms(low[4_800...]), 0.6)
        XCTAssertLessThan(rms(high[4_800...]), 0.02)
    }
}
