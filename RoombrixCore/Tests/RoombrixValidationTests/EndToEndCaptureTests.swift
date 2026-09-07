import XCTest
import Foundation
@testable import RoombrixValidation
@testable import RoombrixAcoustics
@testable import RoombrixDSP

/// MILESTONE 1 ACCEPTANCE as executable tests on real captures.
///
/// CAMPAIGN-DRIVEN: every room folder under `validation/rooms/` is tested
/// automatically — adding a new campaign room (captures + REW export or
/// reference.json) requires NO code changes. Criteria per room:
/// - every capture within ±15 % of the reference across 250 Hz–4 kHz,
/// - consecutive captures pairwise within 3 % per band,
/// - identical fit windows per band across captures.
final class EndToEndCaptureTests: XCTestCase {

    static var validationURL: URL {
        // file → RoombrixValidationTests → Tests → RoombrixCore → repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("validation")
    }

    static var roomsURL: URL { validationURL.appendingPathComponent("rooms") }
    static var recordingsURL: URL { validationURL.appendingPathComponent("recordings") }

    // MARK: - Campaign acceptance (all rooms, no code changes per room)

    func testAllCampaignRoomsMeetAcceptance() throws {
        let rooms = RoomCampaign.discoverRooms(in: Self.roomsURL)
        XCTAssertFalse(rooms.isEmpty, "at least the acceptance room must be present")

        for roomURL in rooms {
            let result = try RoomCampaign.analyze(roomURL: roomURL)
            XCTAssertTrue(result.passedAccuracy,
                          "\(result.name) accuracy FAILED:\n\(result.summaryText)")
            XCTAssertTrue(result.passedRepeatability,
                          "\(result.name) repeatability FAILED:\n\(result.summaryText)")
        }
    }

    // MARK: - Special fixtures (not part of the room campaign)

    func testPathologicalLoudCaptureRecoversRoomDecay() throws {
        // Pre-fix, this capture's 4 kHz read 0.006 s (fit inside the direct
        // pulse). The adaptive window must recover the room from the same
        // data. Room-1 reference, wider ±20 % tolerance (different session
        // at a 12 dB higher playback level).
        let url = Self.recordingsURL
            .appendingPathComponent("roombrix_capture_2026-08-29T17-29-12Z.wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("pathological fixture not present")
        }
        let reference: [Double: Double] = [
            250: 1.041, 500: 0.763, 1_000: 0.685, 2_000: 0.603, 4_000: 0.526,
        ]
        let result = try CapturePipeline.analyze(url: url)
        for (band, ref) in reference {
            guard let decay = result.decays.first(where: { $0.centerFrequency == band }),
                  let rt = ReverbTime.bestEstimate(decay)
            else {
                XCTFail("\(Int(band)) Hz must be measurable")
                continue
            }
            XCTAssertGreaterThan(rt, 0.3, "never a millisecond cliff artifact @ \(Int(band)) Hz")
            XCTAssertEqual(rt, ref, accuracy: ref * 0.20, "@ \(Int(band)) Hz")
        }
    }

    func testSNRMatchesMeasuredPeakToNoiseGap() throws {
        // Independently measured: peak −25.3 dBFS, noise −83.8 dBFS →
        // gap 58.6 dB. The pre-fix estimator reported 25.0 dB on this file.
        let url = Self.roomsURL
            .appendingPathComponent("2026-08-29-room1-domestic/roombrix_capture_2026-08-29T18-50-46Z.wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("room-1 fixture not present")
        }
        let output = try CapturePipeline.analyze(url: url)
        guard let snr = output.snrDB else {
            return XCTFail("SNR must be computable")
        }
        XCTAssertEqual(snr, 58.6, accuracy: 4.0,
                       "estimated SNR must land within a few dB of the measured gap")
    }

    func testFitWindowsNeverExtendBelowTheNoiseLimit() throws {
        // M1 rule (item 4 of the 2026-08-29 review): the window END must
        // never fall below (noise plateau + safety margin). Since
        // usableDecayRangeDB = windowStart − endLimit, the invariant is
        // equivalently: window span ≤ usable range, in EVERY band of EVERY
        // fixture. (A window may legally consume the entire range — end
        // exactly AT the limit — as room 1's 8 kHz band does with its
        // −55…−73 dB window over an 18 dB range.)
        for url in Self.allCaptureURLs() {
            let result = try CapturePipeline.analyze(url: url)
            for decay in result.decays {
                guard let start = decay.windowStartDB,
                      let end = decay.windowEndDB,
                      let usable = decay.usableDecayRangeDB
                else { continue }
                XCTAssertLessThanOrEqual(
                    start - end, usable + 0.01,
                    "\(url.lastPathComponent) @ \(Int(decay.centerFrequency)) Hz: window \(start)…\(end) exceeds usable range \(usable)"
                )
            }
        }
    }

    static func allCaptureURLs() -> [URL] {
        var urls = [recordingsURL
            .appendingPathComponent("roombrix_capture_2026-08-29T17-29-12Z.wav")]
        for room in RoomCampaign.discoverRooms(in: roomsURL) {
            let wavs = ((try? FileManager.default.contentsOfDirectory(
                at: room, includingPropertiesForKeys: nil
            )) ?? []).filter {
                $0.pathExtension.lowercased() == "wav"
                    && $0.lastPathComponent.lowercased().hasPrefix("roombrix_capture")
            }
            urls.append(contentsOf: wavs)
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testEDTNeverReportsImpossibleValues() throws {
        // Sub-20 ms EDT figures were reported on all three 2026-08-29
        // captures before the sanity rule covered every metric.
        var urls = [Self.recordingsURL
            .appendingPathComponent("roombrix_capture_2026-08-29T17-29-12Z.wav")]
        for room in RoomCampaign.discoverRooms(in: Self.roomsURL) {
            // Captures only — room folders also hold REW impulse WAVs etc.
            let wavs = ((try? FileManager.default.contentsOfDirectory(
                at: room, includingPropertiesForKeys: nil
            )) ?? []).filter {
                $0.pathExtension.lowercased() == "wav"
                    && $0.lastPathComponent.lowercased().hasPrefix("roombrix_capture")
            }
            urls.append(contentsOf: wavs)
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let result = try CapturePipeline.analyze(url: url)
            for decay in result.decays {
                if let edt = decay.edt {
                    XCTAssertGreaterThanOrEqual(
                        edt, ReverbTime.minimumPlausibleEDT,
                        "\(url.lastPathComponent) @ \(Int(decay.centerFrequency)) Hz: impossible EDT"
                    )
                }
            }
        }
    }
}
