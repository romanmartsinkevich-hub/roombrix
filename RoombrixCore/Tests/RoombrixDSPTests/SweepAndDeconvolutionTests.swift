import XCTest
@testable import RoombrixDSP

final class SweepAndDeconvolutionTests: XCTestCase {

    /// Short sweep keeps test runtime reasonable while preserving the math.
    /// Band edges sit away from DC and Nyquist: edge ringing of the
    /// bandlimited pulse has period 1/f1, so f1 = 200 Hz keeps it inside a
    /// 10 ms guard window.
    let params = SineSweep.Parameters(
        startFrequency: 200,
        endFrequency: 6_000,
        duration: 1.0,
        sampleRate: 16_000
    )

    func testSweepIsBounded() {
        let sweep = SineSweep(parameters: params)
        XCTAssertEqual(sweep.samples.count, 16_000)
        XCTAssertLessThanOrEqual(sweep.samples.map(abs).max()!, 1.0 + 1e-12)
    }

    func testSweepConvolvedWithInverseIsImpulseLike() {
        let sweep = SineSweep(parameters: params)
        let pulse = FFT.convolve(sweep.samples, sweep.inverseFilter)

        let peakIndex = pulse.enumerated().max { abs($0.element) < abs($1.element) }!.offset
        let peak = abs(pulse[peakIndex])
        XCTAssertEqual(peak, 1.0, accuracy: 0.01, "inverse filter is normalized to unit peak")

        // Energy outside ±20 ms of the peak should be far below the peak.
        // (Band-edge ringing decays ~1/t; production sweeps start at 10–20 Hz,
        // pushing this ringing below the analysis band entirely.)
        let guardBand = Int(0.020 * params.sampleRate)
        var maxSidelobe = 0.0
        for (i, v) in pulse.enumerated() where abs(i - peakIndex) > guardBand {
            maxSidelobe = max(maxSidelobe, abs(v))
        }
        XCTAssertLessThan(maxSidelobe, 0.05, "sidelobes at least ~26 dB below the main peak")
    }

    func testDeconvolutionRecoversEchoPattern() {
        let sweep = SineSweep(parameters: params)
        let fs = params.sampleRate

        // Simulate a "room": direct sound + one echo 25 ms later at −6 dB,
        // with the whole capture delayed 100 ms (unknown playback latency).
        let systemDelay = Int(0.1 * fs)
        let echoDelay = Int(0.025 * fs)
        let echoGain = 0.5
        var recording = [Double](repeating: 0, count: systemDelay + sweep.samples.count + echoDelay + 100)
        for (i, v) in sweep.samples.enumerated() {
            recording[systemDelay + i] += v
            recording[systemDelay + echoDelay + i] += v * echoGain
        }

        let result = Deconvolution.impulseResponse(
            from: recording, sweep: sweep, prePeakSeconds: 0.01, lengthSeconds: 0.2
        )
        let ir = result.impulseResponse
        let peak = result.peakIndex

        // Direct peak should be ~unity after inverse-filter normalization.
        XCTAssertEqual(abs(ir[peak]), 1.0, accuracy: 0.05)

        // The echo appears echoDelay samples after the direct peak at ~echoGain.
        let echoIndex = peak + echoDelay
        XCTAssertLessThan(echoIndex, ir.count)
        let echoRegion = ir[(echoIndex - 2)...(echoIndex + 2)].map(abs).max()!
        XCTAssertEqual(echoRegion, echoGain, accuracy: 0.1)
    }
}
