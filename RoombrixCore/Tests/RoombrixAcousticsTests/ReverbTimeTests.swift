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
        // −55 dB sample noise (EDC plateau ≈ −40 dB): T30 conditions are not
        // met, adaptive selection falls back to T20, and the estimate must
        // stay accurate despite the noise.
        let trueRT = 0.4
        let ir = SyntheticIR.exponentialDecay(
            rt60: trueRT, duration: 1.5, sampleRate: fs, noiseFloorDB: -55
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

    func testAdaptiveMetricSelectionWithLimitedRange() {
        // Sample noise at −58 dB puts the EDC noise plateau at ≈ −43 dB:
        // the T30 fit endpoint (−35 dB) has only ~8 dB of margin, biasing
        // T30 long. Adaptive selection must fall back to T20 and land within
        // 15 % of ground truth. (Observed identically on a real iPhone
        // recording: 500 Hz T30 read +19 % vs REW while T20 read +3 %.)
        let trueRT = 0.5
        let ir = SyntheticIR.exponentialDecay(
            rt60: trueRT, duration: 1.5, sampleRate: fs, noiseFloorDB: -58
        )
        let decays = ReverbTime.analyze(ir, bands: [500, 1_000])
        for band in decays {
            XCTAssertNotNil(band.usableDecayRangeDB)
            XCTAssertLessThan(band.usableDecayRangeDB!, 40, "range must be T20 territory")
            XCTAssertGreaterThanOrEqual(band.usableDecayRangeDB!, 25)
            XCTAssertEqual(band.selectedMetric, .t20, "T20 selected when 25–40 dB available")
            guard let rt = ReverbTime.bestEstimate(band) else {
                XCTFail("band \(band.centerFrequency) should still be measurable via T20")
                continue
            }
            XCTAssertEqual(rt, band.t20!, "estimate must be the T20 figure")
            XCTAssertEqual(rt, trueRT, accuracy: trueRT * 0.15)
        }
    }

    func testAdaptiveMetricUsesT30WhenRangeAllows() {
        let ir = SyntheticIR.exponentialDecay(rt60: 0.5, duration: 1.5, sampleRate: fs)
        let decays = ReverbTime.analyze(ir, bands: [500, 1_000])
        for band in decays {
            XCTAssertGreaterThanOrEqual(band.usableDecayRangeDB ?? 0, 40)
            XCTAssertEqual(band.selectedMetric, .t30)
        }
    }

    func testUnmeasurableBelow25dBRange() {
        let band = ReverbTime.BandDecay(
            centerFrequency: 63, t20: 0.9, t30: 1.2, edt: nil,
            t20FitQuality: 0.95, t30FitQuality: 0.95, usableDecayRangeDB: 20
        )
        XCTAssertEqual(band.selectedMetric, .unmeasurable)
        XCTAssertNil(ReverbTime.bestEstimate(band))
    }

    func testBestEstimateGating() {
        // Cliff artifact: T20 fits the direct-sound cliff with high r² but a
        // nonsense value; T20/T30 curvature must gate the whole band.
        let cliff = ReverbTime.BandDecay(
            centerFrequency: 8_000, t20: 0.001, t30: 0.331, edt: nil,
            t20FitQuality: 0.91, t30FitQuality: 0.36
        )
        XCTAssertNil(ReverbTime.bestEstimate(cliff))

        // Poor T30 fit must not be vouched for by a clean T20 fit; falls
        // back to the T20 value itself.
        let noisyT30 = ReverbTime.BandDecay(
            centerFrequency: 4_000, t20: 0.45, t30: 0.60, edt: nil,
            t20FitQuality: 0.95, t30FitQuality: 0.40
        )
        XCTAssertEqual(ReverbTime.bestEstimate(noisyT30), 0.45)

        // Healthy band: T30 preferred.
        let clean = ReverbTime.BandDecay(
            centerFrequency: 500, t20: 0.48, t30: 0.50, edt: nil,
            t20FitQuality: 0.99, t30FitQuality: 0.99
        )
        XCTAssertEqual(ReverbTime.bestEstimate(clean), 0.50)
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
