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

    func testWAVPCM24RoundTrip() throws {
        let samples = (0..<500).map { sin(2 * .pi * 100 * Double($0) / 48_000) * 0.8 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roombrix-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVFile.writePCM24Mono(samples: samples, sampleRate: 48_000, to: url)
        let audio = try WAVFile.read(url: url)

        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.samples.count, samples.count)
        for (a, b) in zip(audio.samples, samples) {
            XCTAssertEqual(a, b, accuracy: 1.0 / 8_388_607 * 2, "24-bit quantization only")
        }
    }

    func testWAVExtensibleFloat32() throws {
        // WAVE_FORMAT_EXTENSIBLE (0xFFFE) with an IEEE-float SubFormat GUID —
        // what ffmpeg writes for pcm_f32le. Regression: this used to be read
        // as int32 PCM, silently producing garbage samples.
        let samples: [Float] = (0..<200).map { sin(2 * .pi * 500 * Float($0) / 48_000) * 0.7 }
        var data = Data()
        func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 4)
        data.append(contentsOf: "RIFF".utf8); u32(60 + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(40)
        u16(0xFFFE); u16(1)          // extensible, mono
        u32(48_000); u32(48_000 * 4)
        u16(4); u16(32)              // block align, bits
        u16(22)                      // cbSize
        u16(32)                      // valid bits
        u32(0x4)                     // channel mask
        // SubFormat GUID: KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        // {00000003-0000-0010-8000-00AA00389B71} — first two bytes carry the tag.
        u16(3); u16(0)
        data.append(contentsOf: [0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
                                 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        data.append(contentsOf: "data".utf8); u32(dataSize)
        for s in samples {
            var v = s.bitPattern.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        let audio = try WAVFile.parse(data: data)
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertEqual(audio.samples.count, samples.count)
        for (a, b) in zip(audio.samples, samples) {
            XCTAssertEqual(a, Double(b), accuracy: 1e-7)
        }
    }

    func testWAVStereoUsesLeftChannel() throws {
        // Hand-built 16-bit stereo file: left = ramp, right = constant.
        let frames = 100
        var data = Data()
        func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        let dataSize = UInt32(frames * 4)
        data.append(contentsOf: "RIFF".utf8); u32(36 + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16)
        u16(1); u16(2)          // PCM, stereo
        u32(44_100); u32(44_100 * 4)
        u16(4); u16(16)         // block align, bits
        data.append(contentsOf: "data".utf8); u32(dataSize)
        for i in 0..<frames {
            u16(UInt16(bitPattern: Int16(i * 100)))   // left: ramp
            u16(UInt16(bitPattern: Int16(-32_000)))   // right: constant
        }

        let audio = try WAVFile.parse(data: data)
        XCTAssertEqual(audio.sampleRate, 44_100)
        XCTAssertEqual(audio.samples.count, frames)
        XCTAssertEqual(audio.samples[0], 0, accuracy: 1e-9)
        XCTAssertEqual(audio.samples[10], Double(1_000) / 32_768, accuracy: 1e-9, "left channel, not right")
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

    func testParseRealisticEuropeanREWRT60Export() throws {
        // Faithful replica of a real REW RT60 text export from a machine with
        // a European (comma-decimal) locale: * header block, tab-separated
        // columns with unit suffixes, comma decimals, Topt column present.
        let text = "* Measurement: Wohnzimmer Position A\n"
            + "* Dated: 22.08.2026 20:15:03\n"
            + "* REW Version: 5.31.3\n"
            + "* Source: USB, UMIK-1\n"
            + "* Note: RT60 decay data\n"
            + "Band (Hz)\tEDT (s)\tT20 (s)\tT30 (s)\tTopt (s)\n"
            + "   50,0\t  0,834\t  0,712\t  0,698\t  0,705\n"
            + "  125,0\t  0,624\t  0,581\t  0,602\t  0,595\n"
            + "  500,0\t  0,483\t  0,451\t  0,469\t  0,462\n"
            + " 1000,0\t  0,442\t  0,421\t  0,433\t  0,428\n"
            + " 4000,0\t  0,398\t  0,388\t  0,395\t  0,391\n"

        let rows = try REWImport.parseRT60(text: text)
        XCTAssertEqual(rows.count, 5)

        let band500 = rows.first { $0.bandCenter == 500 }
        XCTAssertNotNil(band500)
        // Column mapping must survive the "(s)" unit suffixes: T20 is column
        // index 2, not wherever "(s)" tokens would push it.
        XCTAssertEqual(band500!.edt!, 0.483, accuracy: 1e-9)
        XCTAssertEqual(band500!.t20!, 0.451, accuracy: 1e-9)
        XCTAssertEqual(band500!.t30!, 0.469, accuracy: 1e-9)

        let band50 = rows.first { $0.bandCenter == 50 }
        XCTAssertEqual(band50!.t30!, 0.698, accuracy: 1e-9)
    }

    func testParseREWv540RT60Export() throws {
        // Verbatim structure of a real REW V5.40 Beta export (as uploaded to
        // validation/rew/): prose header WITHOUT '*' prefixes, a "Format is"
        // column-description line, data rows with non-numeric column tokens
        // ("1/3", "Forward"), and a trailing "full" summary row.
        let text = """
        RT60 data saved by REW V5.40 Beta 133
        Note: measure 1
        Source: OmniMic, No name 1, R, Volume: 1.000
        Dated: Aug 23, 2026, 6:15:16 PM
        Measurement: R Aug 23_1
        Sweep level: -12.0 dBFS
        Response measured over: 0.4 to 19,999.9 Hz
        Peak value: 0.0021381665 at index 48000
        Response length: 131072 samples
        Sample interval: 2.0833333333333333E-5 seconds
        Start time: -0.9999999993401905 seconds

        Format is freq (Hz), BW (octaves), EDT (s), r, T20 (s), r, T30 (s), r, Topt (s), r, ToptStart (dB), ToptEnd (dB), T60M (s), reverse/forward/zero phase filtered, C50 (dB), C80 (dB), C20 (dB), D50 (%), TS (s)

        50 1/3 2.067 -0.976 1.516 -0.983 1.610 -0.993 1.610 -0.994 -5.000 -39.000 0.000 Forward 0.85 1.09 0.03 54.9 0.140
        500 1/3 0.181 -0.913 0.672 -0.984 0.731 -0.990 0.789 -0.997 -11.000 -51.000 0.000 Forward 12.88 16.39 9.08 95.1 0.017
        1000 1/3 0.706 -0.956 0.623 -0.995 0.668 -0.995 0.640 -0.997 -5.000 -33.000 0.000 Forward 6.24 9.40 3.26 80.8 0.028

        full 1/3 0.425 -0.979 0.690 -0.991 0.812 -0.993 0.534 -0.998 -5.000 -17.000 0.000 Forward 10.07 13.00 5.38 91.0 0.015
        """

        let rows = try REWImport.parseRT60(text: text)
        // Exactly the 3 band rows: prose lines and the "full" row must not
        // become junk rows (e.g. "Dated: Aug 23, 2026" parsing as band 23).
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.bandCenter), [50, 500, 1_000])

        let band500 = rows[1]
        XCTAssertEqual(band500.edt!, 0.181, accuracy: 1e-9)
        XCTAssertEqual(band500.t20!, 0.672, accuracy: 1e-9)
        XCTAssertEqual(band500.t30!, 0.731, accuracy: 1e-9)

        let band50 = rows[0]
        XCTAssertEqual(band50.t30!, 1.610, accuracy: 1e-9)
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
