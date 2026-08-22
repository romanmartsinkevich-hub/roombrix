import XCTest
@testable import RoombrixAcoustics
@testable import RoombrixDSP

final class ClarityAndDetectionTests: XCTestCase {

    let fs = 16_000.0

    /// For a pure exponential decay with reverberation time RT, the expected
    /// C80 is analytic: energy envelope E(t) ∝ 10^(−6 t / RT), so
    /// C80 = 10 log10(10^(0.48 / RT) − 1).
    func testC80MatchesAnalyticValue() {
        let rt = 0.5
        let ir = SyntheticIR.exponentialDecay(rt60: rt, duration: 2.0, sampleRate: fs)
        let expected = 10 * log10(pow(10, 0.48 / rt) - 1)  // ≈ 9.1 dB for RT 0.5

        guard let c80 = Clarity.c80(ir) else {
            return XCTFail("C80 not computed")
        }
        XCTAssertEqual(c80, expected, accuracy: 1.0)
    }

    func testClarityOrdering() {
        // Faster decay ⇒ higher clarity, always.
        let dry = SyntheticIR.exponentialDecay(rt60: 0.3, duration: 1.5, sampleRate: fs)
        let wet = SyntheticIR.exponentialDecay(rt60: 1.5, duration: 3.0, sampleRate: fs)
        let c80Dry = Clarity.c80(dry)!
        let c80Wet = Clarity.c80(wet)!
        XCTAssertGreaterThan(c80Dry, c80Wet + 6)

        let d50 = Clarity.d50(dry)!
        XCTAssertGreaterThan(d50, 0.5)
        XCTAssertLessThanOrEqual(d50, 1.0)
    }

    func testFlutterEchoDetected() {
        let period = 0.020  // 20 ms → 3.43 m wall spacing
        let ir = SyntheticIR.flutter(period: period, duration: 1.0, sampleRate: fs)
        guard let detection = FlutterEcho.detect(in: ir) else {
            return XCTFail("flutter not detected")
        }
        XCTAssertEqual(detection.period, period, accuracy: 0.002)
        XCTAssertEqual(detection.surfaceSpacing, 3.43, accuracy: 0.4)
        XCTAssertGreaterThan(detection.strength, 0.15)
    }

    func testNoFlutterOnSmoothDecay() {
        let ir = SyntheticIR.exponentialDecay(rt60: 0.5, duration: 1.0, sampleRate: fs)
        XCTAssertNil(FlutterEcho.detect(in: ir), "smooth diffuse decay must not trigger flutter")
    }

    func testLowFrequencyPeakDetection() {
        let ir = SyntheticIR.modalIR(
            modeFrequency: 100, modeRT60: 1.2, broadbandRT60: 0.4,
            duration: 2.0, sampleRate: fs
        )
        let curve = FrequencyResponse.smoothedMagnitude(of: ir, minFrequency: 30, maxFrequency: 2_000)
        let peaks = FrequencyResponse.lowFrequencyPeaks(in: curve)
        XCTAssertFalse(peaks.isEmpty, "the 100 Hz mode must show up as an LF peak")
        let nearest = peaks.min { abs($0.frequency - 100) < abs($1.frequency - 100) }!
        XCTAssertEqual(nearest.frequency, 100, accuracy: 8)
        XCTAssertGreaterThan(nearest.prominenceDB, 5)
    }

    func testNoiseFloorAndSNR() {
        let quiet = [Double](repeating: 0.0001, count: 8_000)
        let loud = [Double](repeating: 0.3, count: 8_000)

        let estimate = NoiseFloor.estimate(ambient: quiet)
        XCTAssertNotNil(estimate)
        XCTAssertLessThan(estimate!.levelDBFS, -70)

        let snr = NoiseFloor.signalToNoiseDB(signal: loud, ambient: quiet)
        XCTAssertNotNil(snr)
        XCTAssertGreaterThan(snr!, 60)
    }

    func testSpatialAverage() {
        let a = FrequencyResponse.Curve(frequencies: [100, 200], levelsDB: [0, -10])
        let b = FrequencyResponse.Curve(frequencies: [100, 200], levelsDB: [0, 10])
        let avg = FrequencyResponse.spatialAverage([a, b])
        XCTAssertNotNil(avg)
        XCTAssertEqual(avg!.levelsDB[0], 0, accuracy: 1e-9)
        // Power average of −10 and +10 dB is ~+7 dB (dominated by the louder).
        XCTAssertEqual(avg!.levelsDB[1], 7.0, accuracy: 0.1)
    }

    func testFullPipelineOnHostileRealisticIR() {
        // Direct peak at a nonzero index, aperiodic early reflections,
        // −55 dB noise floor, and a DC offset — all at once.
        let trueRT = 0.5
        let (ir, expectedDirectIndex) = SyntheticIR.realisticRoom(
            rt60: trueRT, duration: 1.5, sampleRate: fs
        )

        // Peak auto-detection must land on the direct sound, not lead-in
        // noise or a reflection.
        XCTAssertEqual(ir.directIndex, expectedDirectIndex)

        let report = RoomAnalyzer.analyze(
            primary: ir,
            ambient: (0..<4_000).map { _ in Double.random(in: -0.002...0.002) }
        )

        // Decay: the diffuse tail carries the RT; direct/early structure and
        // DC must not derail the band estimates (DC is outside every band).
        guard let mid = report.midBandRT60 else {
            return XCTFail("mid-band RT60 not recovered from realistic IR")
        }
        XCTAssertEqual(mid, trueRT, accuracy: trueRT * 0.20)
        for band in report.bandDecays where band.centerFrequency >= 250 && band.centerFrequency <= 4_000 {
            guard let rt = ReverbTime.bestEstimate(band) else {
                XCTFail("no RT for \(band.centerFrequency) Hz band")
                continue
            }
            XCTAssertEqual(rt, trueRT, accuracy: trueRT * 0.25, "band \(band.centerFrequency) Hz")
        }

        // Clarity: strong direct + early energy inside 80 ms ⇒ positive C80.
        XCTAssertNotNil(report.c80)
        XCTAssertGreaterThan(report.c80!, 0)
        XCTAssertTrue(report.c80!.isFinite)

        // Aperiodic reflections must not read as flutter.
        XCTAssertNil(report.flutterEcho)

        // The rest of the report is populated and sane.
        XCTAssertNotNil(report.noiseFloor)
        XCTAssertFalse(report.frequencyResponse.frequencies.isEmpty)
        XCTAssertTrue(report.smoothnessDeviationDB.isFinite)
    }

    func testFullAnalyzerPipeline() {
        let ir = SyntheticIR.exponentialDecay(rt60: 0.6, duration: 2.0, sampleRate: fs)
        let report = RoomAnalyzer.analyze(primary: ir, ambient: [Double](repeating: 0.001, count: 4_000))

        XCTAssertNotNil(report.midBandRT60)
        XCTAssertEqual(report.midBandRT60!, 0.6, accuracy: 0.09)
        XCTAssertNotNil(report.c80)
        XCTAssertNotNil(report.noiseFloor)
        XCTAssertFalse(report.bandDecays.isEmpty)
        XCTAssertFalse(report.frequencyResponse.frequencies.isEmpty)
    }
}
