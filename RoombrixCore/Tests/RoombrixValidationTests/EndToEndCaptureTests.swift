import XCTest
import Foundation
@testable import RoombrixValidation
@testable import RoombrixAcoustics
@testable import RoombrixDSP

/// MILESTONE 1 ACCEPTANCE, as executable tests on the real uploaded
/// captures in validation/recordings/:
/// - two consecutive captures agree within 3 % per band,
/// - both land within 15 % of the REW reference across 250 Hz–4 kHz,
/// - the pre-fix pathological capture (excessive level, 4 kHz once read
///   0.006 s) recovers the room's decay,
/// - the SNR estimate matches the independently measured peak-to-noise gap.
final class EndToEndCaptureTests: XCTestCase {

    // REW reference values for the acceptance room (2026-08-29 session).
    static let rewReference: [Double: Double] = [
        250: 1.041, 500: 0.763, 1_000: 0.685, 2_000: 0.603, 4_000: 0.526,
    ]
    static let criteriaBands: [Double] = [250, 500, 1_000, 2_000, 4_000]

    static var recordingsURL: URL {
        // file → RoombrixValidationTests → Tests → RoombrixCore → repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // strip file name
            .deletingLastPathComponent()   // RoombrixValidationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RoombrixCore
            .appendingPathComponent("validation/recordings")
    }

    struct PipelineResult {
        let decays: [ReverbTime.BandDecay]
        let snrDB: Double?
        let report: AcousticReport
    }

    /// Full pipeline exactly as `roombrix-validate measure` / the app run it.
    static func run(file: String) throws -> PipelineResult {
        let url = recordingsURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture \(file) not present in validation/recordings")
        }
        let audio = try WAVFile.read(url: url)
        let fs = audio.sampleRate
        let sweep = SineSweep(parameters: .init(
            startFrequency: 20, endFrequency: 20_000, duration: 10, sampleRate: fs
        ))
        let marker = TimingReference.makeMarker(sampleRate: fs)
        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: sweep.samples.count)
        let guardSamples = Int(marker.guardInterval * fs)
        let requiredTrailing = marker.samples.count + guardSamples + sweep.samples.count

        guard let detection = TimingReference.detect(
            marker: marker, in: audio.samples,
            expectedMarkerSpacing: spacing,
            requiredTrailingSamples: requiredTrailing
        ), detection.confidenceDB >= TimingReference.minimumConfidenceDB else {
            throw NSError(domain: "EndToEnd", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "marker not detected in \(file)",
            ])
        }

        let snr = NoiseFloor.peakToNoiseGapDB(
            recording: audio.samples,
            markerStartIndex: detection.markerStartIndex,
            sampleRate: fs
        )
        let aligned = Array(audio.samples[min(detection.stimulusStartIndex, audio.samples.count - 1)...])
        let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
        let ir = ImpulseResponse(
            samples: deconvolved.impulseResponse,
            sampleRate: deconvolved.sampleRate,
            directIndex: deconvolved.peakIndex
        )
        let report = RoomAnalyzer.analyze(primary: ir)
        return PipelineResult(decays: report.bandDecays, snrDB: snr, report: report)
    }

    func band(_ decays: [ReverbTime.BandDecay], _ center: Double) -> ReverbTime.BandDecay? {
        decays.first { $0.centerFrequency == center }
    }

    // MARK: - Acceptance

    func testConsecutiveCapturesMeetAcceptance() throws {
        let take1 = try Self.run(file: "roombrix_capture_2026-08-29T18-48-12Z.wav")
        let take2 = try Self.run(file: "roombrix_capture_2026-08-29T18-50-46Z.wav")

        for center in Self.criteriaBands {
            guard let band1 = band(take1.decays, center),
                  let band2 = band(take2.decays, center),
                  let rt1 = ReverbTime.bestEstimate(band1),
                  let rt2 = ReverbTime.bestEstimate(band2)
            else {
                XCTFail("\(Int(center)) Hz must be measurable in both takes")
                continue
            }
            let reference = Self.rewReference[center]!

            // Within 15 % of the REW reference, both takes.
            XCTAssertEqual(rt1, reference, accuracy: reference * 0.15,
                           "take 1 @ \(Int(center)) Hz vs REW")
            XCTAssertEqual(rt2, reference, accuracy: reference * 0.15,
                           "take 2 @ \(Int(center)) Hz vs REW")

            // Take-to-take within 3 %.
            XCTAssertEqual(rt1, rt2, accuracy: rt2 * 0.03,
                           "repeatability @ \(Int(center)) Hz: \(rt1) vs \(rt2)")

            // Deterministic window selection: identical per band.
            XCTAssertEqual(band1.windowStartDB, band2.windowStartDB,
                           "window start must match across takes @ \(Int(center)) Hz")
            XCTAssertEqual(band1.windowEndDB, band2.windowEndDB,
                           "window end must match across takes @ \(Int(center)) Hz")
        }
    }

    func testPathologicalLoudCaptureRecoversRoomDecay() throws {
        // Pre-fix, this capture's 4 kHz read 0.006 s (fit inside the direct
        // pulse) and 8 kHz 0.001 s. The adaptive window must recover the
        // room from the same data.
        let result = try Self.run(file: "roombrix_capture_2026-08-29T17-29-12Z.wav")
        for center in Self.criteriaBands {
            guard let decay = band(result.decays, center),
                  let rt = ReverbTime.bestEstimate(decay)
            else {
                XCTFail("\(Int(center)) Hz must be measurable")
                continue
            }
            XCTAssertGreaterThan(rt, 0.3, "never a millisecond cliff artifact @ \(Int(center)) Hz")
            let reference = Self.rewReference[center]!
            XCTAssertEqual(rt, reference, accuracy: reference * 0.20,
                           "@ \(Int(center)) Hz (pathological capture, wider ±20 % tolerance)")
        }
    }

    func testSNRMatchesMeasuredPeakToNoiseGap() throws {
        // Independently measured (item 1 of the 2026-08-29 review):
        // peak −25.3 dBFS, noise −83.8 dBFS → gap 58.6 dB. The previous
        // estimator reported 25.0 dB on this capture.
        let take = try Self.run(file: "roombrix_capture_2026-08-29T18-50-46Z.wav")
        guard let snr = take.snrDB else {
            return XCTFail("SNR must be computable")
        }
        XCTAssertEqual(snr, 58.6, accuracy: 4.0,
                       "estimated SNR must land within a few dB of the measured gap")
    }

    func testEDTNeverReportsImpossibleValues() throws {
        // Item 7: EDT 0.001–0.013 s was reported on all three captures.
        for file in [
            "roombrix_capture_2026-08-29T17-29-12Z.wav",
            "roombrix_capture_2026-08-29T18-48-12Z.wav",
            "roombrix_capture_2026-08-29T18-50-46Z.wav",
        ] {
            let result = try Self.run(file: file)
            for decay in result.decays {
                if let edt = decay.edt {
                    XCTAssertGreaterThanOrEqual(
                        edt, ReverbTime.minimumPlausibleEDT,
                        "\(file) @ \(Int(decay.centerFrequency)) Hz: impossible EDT"
                    )
                }
            }
        }
    }
}
