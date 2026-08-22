import XCTest
@testable import RoombrixAcoustics
@testable import RoombrixDSP

final class ReverbTimeTests: XCTestCase {

    let fs = 16_000.0

    func testRecoversKnownRT60() {
        let trueRT = 0.5
        let ir = SyntheticIR.exponentialDecay(rt60: trueRT, duration: 1.5, sampleRate: fs)
        let decays = ReverbTime.analyze(ir, bands: [250, 500, 1_000, 2_000])

        for band in decays {
            guard let rt = ReverbTime.bestEstimate(band) else {
                XCTFail("no RT estimate for \(band.centerFrequency) Hz")
                continue
            }
            XCTAssertEqual(
                rt, trueRT, accuracy: trueRT * 0.10,
                "band \(band.centerFrequency) Hz within ±10 % of ground truth"
            )
        }
    }

    func testRecoversLongRT60() {
        let trueRT = 1.2
        let ir = SyntheticIR.exponentialDecay(rt60: trueRT, duration: 3.0, sampleRate: fs)
        let decays = ReverbTime.analyze(ir, bands: [500, 1_000])
        for band in decays {
            let rt = ReverbTime.bestEstimate(band)
            XCTAssertNotNil(rt)
            XCTAssertEqual(rt!, trueRT, accuracy: trueRT * 0.10)
        }
    }

    func testRobustToNoiseFloor() {
        // −45 dB noise floor: T30 range (−5…−35) sits right at the edge, so
        // noise truncation must engage for the estimate to stay honest.
        let trueRT = 0.4
        let ir = SyntheticIR.exponentialDecay(
            rt60: trueRT, duration: 1.5, sampleRate: fs, noiseFloorDB: -45
        )
        let decays = ReverbTime.analyze(ir, bands: [500, 1_000])
        for band in decays {
            guard let rt = ReverbTime.bestEstimate(band) else {
                XCTFail("estimate lost to noise")
                continue
            }
            XCTAssertEqual(rt, trueRT, accuracy: trueRT * 0.15)
        }
    }

    func testBandDependentDecayAndRatio() {
        // Bass rings 2× longer than mids — the classic boomy room.
        let ir = SyntheticIR.bandDependentDecay(
            bandRT60: [125: 0.9, 250: 0.8, 500: 0.45, 1_000: 0.45, 2_000: 0.4],
            duration: 2.5,
            sampleRate: fs
        )
        let decays = ReverbTime.analyze(ir, bands: [125, 250, 500, 1_000, 2_000])

        let lf125 = decays.first { $0.centerFrequency == 125 }.flatMap { ReverbTime.bestEstimate($0) }
        let mid1k = decays.first { $0.centerFrequency == 1_000 }.flatMap { ReverbTime.bestEstimate($0) }
        XCTAssertNotNil(lf125)
        XCTAssertNotNil(mid1k)
        XCTAssertGreaterThan(lf125!, mid1k! * 1.4, "LF decay clearly longer than mid")

        let ratio = ReverbTime.lowToMidDecayRatio(decays)
        XCTAssertNotNil(ratio)
        XCTAssertGreaterThan(ratio!, 1.5)

        let mid = ReverbTime.midBandRT60(decays)
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid!, 0.45, accuracy: 0.1)
    }

    func testSchroederCurveIsMonotonicallyDecreasing() {
        let ir = SyntheticIR.exponentialDecay(rt60: 0.5, duration: 1.0, sampleRate: fs)
        let curve = SchroederIntegration.decayCurve(of: ir.samples, sampleRate: fs)
        XCTAssertEqual(curve.levelsDB[0], 0, accuracy: 1e-9)
        for i in 1..<curve.truncationIndex {
            XCTAssertLessThanOrEqual(curve.levelsDB[i], curve.levelsDB[i - 1] + 1e-12)
        }
    }

    func testRepeatability() {
        // Two different noise realizations of the same room must agree —
        // the analog of the brief's ±2-point repeatability requirement.
        let a = SyntheticIR.exponentialDecay(rt60: 0.5, duration: 1.5, sampleRate: fs, seed: 1)
        let b = SyntheticIR.exponentialDecay(rt60: 0.5, duration: 1.5, sampleRate: fs, seed: 2)
        let rtA = ReverbTime.midBandRT60(ReverbTime.analyze(a, bands: [500, 1_000]))
        let rtB = ReverbTime.midBandRT60(ReverbTime.analyze(b, bands: [500, 1_000]))
        XCTAssertNotNil(rtA)
        XCTAssertNotNil(rtB)
        XCTAssertEqual(rtA!, rtB!, accuracy: 0.05)
    }
}
