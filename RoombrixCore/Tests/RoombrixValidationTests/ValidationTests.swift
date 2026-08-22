import XCTest
import Foundation
@testable import RoombrixValidation
@testable import RoombrixAcoustics

final class ValidationTests: XCTestCase {

    // MARK: - WAV

    func testWAVFloat32RoundTrip() throws {
        let samples = (0..<1_000).map { sin(2 * .pi * 440 * Double($0) / 48_000) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roombrix-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVFile.writeFloat32Mono(samples: samples, sampleRate: 48_000, to: url)
        let audio = try WAVFile.read(url: url)

        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.samples.count, samples.count)
        for (a, b) in zip(audio.samples, samples) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testWAVRejectsGarbage() {
        XCTAssertThrowsError(try WAVFile.parse(data: Data(repeating: 7, count: 100)))
    }

    // MARK: - REW imports

    func testParseREWFrequencyResponseExport() throws {
        let text = """
        * Measurement data measured by REW V5.20
        * Source: USB, UMIK-1
        * Format: 48000 Hz, float, mono
        * Freq(Hz) SPL(dB) Phase(degrees)
        20.000 68.42 -12.3
        25.000 71.10 -18.9
        1000.000 75.55 45.0
        """
        let points = try REWImport.parseFrequencyResponse(text: text)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].frequency, 20)
        XCTAssertEqual(points[0].spl, 68.42, accuracy: 1e-9)
        XCTAssertEqual(points[0].phase!, -12.3, accuracy: 1e-9)
        XCTAssertEqual(points[2].frequency, 1_000)
    }

    func testParseREWRT60Export() throws {
        let text = """
        * RT60 data
        Band  EDT  T20  T30
        125   0.62 0.58 0.60
        250   0.55 0.52 0.54
        500   0.48 0.45 0.47
        1000  0.44 0.42 0.43
        2000  0.41 0.40 0.41
        """
        let rows = try REWImport.parseRT60(text: text)
        XCTAssertEqual(rows.count, 5)
        let band500 = rows.first { $0.bandCenter == 500 }
        XCTAssertNotNil(band500)
        XCTAssertEqual(band500!.t20!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(band500!.t30!, 0.47, accuracy: 1e-9)
        XCTAssertEqual(band500!.edt!, 0.48, accuracy: 1e-9)
    }

    // MARK: - European locale exports (decimal commas)

    func testDecimalCommaDoesNotSilentlyMisparse() {
        // Regression: "0,45" previously split on the comma into 0 and 45.
        XCTAssertEqual(REWImport.numericFields(of: "500\t0,45"), [500, 0.45])
        XCTAssertEqual(REWImport.numericFields(of: "500 0,45 0,47"), [500, 0.45, 0.47])
    }

    func testDotDecimalLinesKeepCommaAsFieldSeparator() {
        // US-locale CSV: dots present, so commas separate fields.
        XCTAssertEqual(REWImport.numericFields(of: "500.0,0.45,0.47"), [500.0, 0.45, 0.47])
    }

    func testParseEuropeanRT60Export() throws {
        let text = """
        * RT60 data (European locale)
        Band  EDT  T20  T30
        125   0,62 0,58 0,60
        500   0,48 0,45 0,47
        1000  0,44 0,42 0,43
        """
        let rows = try REWImport.parseRT60(text: text)
        XCTAssertEqual(rows.count, 3)
        let band500 = rows.first { $0.bandCenter == 500 }
        XCTAssertNotNil(band500)
        XCTAssertEqual(band500!.t20!, 0.45, accuracy: 1e-9)
        XCTAssertEqual(band500!.t30!, 0.47, accuracy: 1e-9)
        XCTAssertEqual(band500!.edt!, 0.48, accuracy: 1e-9)
    }

    func testParseSemicolonSeparatedEuropeanFrequencyResponse() throws {
        let text = """
        * Measurement data measured by REW V5.20 (European locale)
        * Freq(Hz);SPL(dB);Phase(degrees)
        20,000;68,42;-12,3
        1000,000;75,55;45,0
        """
        let points = try REWImport.parseFrequencyResponse(text: text)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].frequency, 20, accuracy: 1e-9)
        XCTAssertEqual(points[0].spl, 68.42, accuracy: 1e-9)
        XCTAssertEqual(points[0].phase!, -12.3, accuracy: 1e-9)
        XCTAssertEqual(points[1].frequency, 1_000, accuracy: 1e-9)
    }

    func testParseRejectsEmptyAndGarbage() {
        XCTAssertThrowsError(try REWImport.parseFrequencyResponse(text: ""))
        XCTAssertThrowsError(try REWImport.parseRT60(text: "* only comments\n* nothing else"))
    }

    // MARK: - Comparison harness

    func makeDecay(_ center: Double, rt: Double) -> ReverbTime.BandDecay {
        .init(centerFrequency: center, t20: rt, t30: rt, edt: rt, t20FitQuality: 0.99)
    }

    func makeReference(_ pairs: [(Double, Double)]) -> [REWImport.RT60Row] {
        pairs.map { .init(bandCenter: $0.0, edt: nil, t20: $0.1, t30: $0.1) }
    }

    func testComparisonPassesWithinTolerance() {
        // 8 % error everywhere — inside the ±15 % acceptance band.
        let ours = [makeDecay(500, rt: 0.54), makeDecay(1_000, rt: 0.54), makeDecay(2_000, rt: 0.54)]
        let reference = makeReference([(500, 0.5), (1_000, 0.5), (2_000, 0.5)])
        let report = ComparisonHarness.compareRT60(roombrix: ours, reference: reference)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.summary.contains("PASS"))
    }

    func testComparisonFailsOutsideTolerance() {
        // 30 % error at 1 kHz — must fail the acceptance criteria.
        let ours = [makeDecay(500, rt: 0.5), makeDecay(1_000, rt: 0.65)]
        let reference = makeReference([(500, 0.5), (1_000, 0.5)])
        let report = ComparisonHarness.compareRT60(roombrix: ours, reference: reference)
        XCTAssertFalse(report.passed)
        let band1k = report.bands.first { $0.bandCenter == 1_000 }
        XCTAssertEqual(band1k?.withinTolerance, false)
        XCTAssertEqual(band1k!.relativeError!, 0.3, accuracy: 1e-9)
    }

    func testComparisonIgnoresBandsOutsideCriteria() {
        // A miss at 63 Hz must not fail the run (criteria are 500 Hz–2 kHz),
        // but it is still reported.
        let ours = [makeDecay(63, rt: 1.5), makeDecay(500, rt: 0.5), makeDecay(1_000, rt: 0.5), makeDecay(2_000, rt: 0.5)]
        let reference = makeReference([(63, 0.9), (500, 0.5), (1_000, 0.5), (2_000, 0.5)])
        let report = ComparisonHarness.compareRT60(roombrix: ours, reference: reference)
        XCTAssertTrue(report.passed)
        let band63 = report.bands.first { $0.bandCenter == 63 }
        XCTAssertEqual(band63?.withinTolerance, false)
    }

    func testComparisonRequiresCriteriaBands() {
        // No overlap with 500 Hz–2 kHz → cannot pass.
        let ours = [makeDecay(63, rt: 0.5)]
        let reference = makeReference([(63, 0.5)])
        let report = ComparisonHarness.compareRT60(roombrix: ours, reference: reference)
        XCTAssertFalse(report.passed)
    }
}
