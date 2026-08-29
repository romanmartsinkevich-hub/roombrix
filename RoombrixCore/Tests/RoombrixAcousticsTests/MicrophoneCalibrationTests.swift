import XCTest
@testable import RoombrixAcoustics

final class MicrophoneCalibrationTests: XCTestCase {

    let umikStyleText = """
    "Sens Factor =-0.882dB, SERNO: 7001234"
    20.0\t-2.5
    100.0\t-0.5
    1000.0\t0.0
    10000.0\t1.5
    20000.0\t3.0
    """

    func testParsesUMIKStyleFile() {
        let cal = MicrophoneCalibration(text: umikStyleText, label: "UMIK test")
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!.points.count, 5)
        XCTAssertEqual(cal!.points.first!.frequency, 20)
        XCTAssertEqual(cal!.points.first!.gainDB, -2.5, accuracy: 1e-9)
    }

    func testRejectsFilesWithoutData() {
        XCTAssertNil(MicrophoneCalibration(text: "\"header only\"\nnot numbers here", label: "x"))
        XCTAssertNil(MicrophoneCalibration(text: "100.0 -1.0", label: "single point"))
    }

    func testInterpolationAndClamping() {
        let cal = MicrophoneCalibration(text: umikStyleText, label: "UMIK test")!
        // Exact points.
        XCTAssertEqual(cal.gain(at: 1_000), 0.0, accuracy: 1e-9)
        XCTAssertEqual(cal.gain(at: 20_000), 3.0, accuracy: 1e-9)
        // Log-frequency midpoint between 1 kHz (0 dB) and 10 kHz (1.5 dB):
        // sqrt(1000·10000) ≈ 3162 Hz → 0.75 dB.
        XCTAssertEqual(cal.gain(at: 3_162.28), 0.75, accuracy: 0.01)
        // Clamped outside the curve.
        XCTAssertEqual(cal.gain(at: 5), -2.5, accuracy: 1e-9)
        XCTAssertEqual(cal.gain(at: 40_000), 3.0, accuracy: 1e-9)
    }

    func testAppliesToFrequencyResponseOnly() {
        let cal = MicrophoneCalibration(text: umikStyleText, label: "UMIK test")!
        let ir = SyntheticIR.exponentialDecay(rt60: 0.5, duration: 1.5, sampleRate: 16_000)

        let plain = RoomAnalyzer.analyze(primary: ir)
        let calibrated = RoomAnalyzer.analyze(primary: ir, calibration: cal)

        // FR changes by exactly the mic curve…
        let i = plain.frequencyResponse.frequencies.firstIndex { $0 >= 1_000 }!
        let f = plain.frequencyResponse.frequencies[i]
        XCTAssertEqual(
            calibrated.frequencyResponse.levelsDB[i],
            plain.frequencyResponse.levelsDB[i] - cal.gain(at: f),
            accuracy: 1e-9
        )

        // …while every decay figure is bit-identical (hard rule: calibration
        // never touches time-domain metrics).
        XCTAssertEqual(plain.bandDecays.count, calibrated.bandDecays.count)
        for (a, b) in zip(plain.bandDecays, calibrated.bandDecays) {
            XCTAssertEqual(a.t20, b.t20)
            XCTAssertEqual(a.t30, b.t30)
            XCTAssertEqual(a.edt, b.edt)
        }
        XCTAssertEqual(plain.c80, calibrated.c80)
        XCTAssertEqual(plain.midBandRT60, calibrated.midBandRT60)
    }

    func testEuropeanDecimalCommaCalFile() {
        let cal = MicrophoneCalibration(text: "20,0 -2,5\n1000,0 0,0\n20000,0 3,0", label: "eu")
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!.gain(at: 20), -2.5, accuracy: 1e-9)
    }
}
