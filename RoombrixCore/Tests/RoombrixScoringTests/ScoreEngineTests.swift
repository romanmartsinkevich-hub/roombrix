import XCTest
@testable import RoombrixScoring
@testable import RoombrixAcoustics
@testable import RoombrixGeometry
import RoombrixDSP

final class ScoreEngineTests: XCTestCase {

    // MARK: - Report builders

    func makeReport(
        rt60: Double,
        lfRatio: Double = 1.0,
        smoothness: Double = 2.0,
        c80: Double = 4.0,
        peaks: [(frequency: Double, prominenceDB: Double)] = [],
        flutter: FlutterEcho.Detection? = nil
    ) -> AcousticReport {
        let bands = OctaveBand.standardCenters.map { center in
            ReverbTime.BandDecay(
                centerFrequency: center,
                t20: center <= 250 ? rt60 * lfRatio : rt60,
                t30: center <= 250 ? rt60 * lfRatio : rt60,
                edt: rt60,
                t20FitQuality: 0.99
            )
        }
        return AcousticReport(
            bandDecays: bands,
            midBandRT60: rt60,
            lowToMidDecayRatio: lfRatio,
            c50: c80 - 2,
            c80: c80,
            d50: 0.7,
            flutterEcho: flutter,
            frequencyResponse: .init(frequencies: [100, 1_000], levelsDB: [0, 0]),
            smoothnessDeviationDB: smoothness,
            lowFrequencyPeaks: peaks,
            noiseFloor: .init(levelDBFS: -65, descriptor: "quiet")
        )
    }

    // MARK: - Structure

    func testWeightsSumToOne() {
        let total = SubscoreKind.allCases.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(total, 1.0, accuracy: 1e-12)
    }

    func testScoreIsVersionedAndComplete() {
        let score = ScoreEngine.score(.init(report: makeReport(rt60: 0.4)))
        XCTAssertEqual(score.engineVersion, ScoreEngine.version)
        XCTAssertEqual(score.subscores.count, SubscoreKind.allCases.count)
        for subscore in score.subscores {
            XCTAssertFalse(subscore.explanation.isEmpty, "\(subscore.kind) must be explainable")
            XCTAssertTrue((0...100).contains(subscore.value))
        }
        XCTAssertTrue((0...100).contains(score.value))
    }

    func testGoodRoomScoresHigh() {
        let geometry = RoomGeometry(length: 5, width: 4, height: 2.5)
        let score = ScoreEngine.score(.init(
            report: makeReport(rt60: 0.4),
            geometry: geometry,
            purpose: .listening
        ))
        XCTAssertGreaterThan(score.value, 80, "well-behaved room should score high")
    }

    func testBadRoomScoresLowAndBelowGoodRoom() {
        let geometry = RoomGeometry(length: 5, width: 4, height: 2.5)
        let good = ScoreEngine.score(.init(report: makeReport(rt60: 0.4), geometry: geometry))
        let bad = ScoreEngine.score(.init(
            report: makeReport(
                rt60: 1.4,
                lfRatio: 2.0,
                smoothness: 8.0,
                c80: -4,
                peaks: [(45, 12), (68, 8)],
                flutter: .init(period: 0.02, surfaceSpacing: 3.4, strength: 0.4)
            ),
            geometry: geometry
        ))
        XCTAssertLessThan(bad.value, 40)
        XCTAssertGreaterThan(good.value - bad.value, 30)
    }

    func testConfidenceRangeByMicrophone() {
        let report = makeReport(rt60: 0.4)
        let internalScore = ScoreEngine.score(.init(report: report, microphone: .internalMic))
        let externalScore = ScoreEngine.score(.init(report: report, microphone: .calibratedExternal))

        let internalWidth = internalScore.range.upperBound - internalScore.range.lowerBound
        let externalWidth = externalScore.range.upperBound - externalScore.range.lowerBound
        XCTAssertEqual(internalWidth, 6, accuracy: 1e-9, "internal mic: ±3 points")
        XCTAssertEqual(externalWidth, 2, accuracy: 1e-9, "calibrated mic: ±1 point")
        XCTAssertGreaterThan(internalWidth, externalWidth)
    }

    func testBoomyBassExplanationIsPlainLanguage() {
        let score = ScoreEngine.score(.init(report: makeReport(rt60: 0.4, lfRatio: 2.0)))
        let uniformity = score.subscores.first { $0.kind == .decayUniformity }!
        XCTAssertLessThan(uniformity.value, 60)
        XCTAssertTrue(uniformity.explanation.contains("boomy"),
                      "explanation should be the plain-language sentence from the brief")
    }

    func testPurposeTargetsScaleWithVolume() {
        let small = RoomPurpose.listening.rt60Target(volume: 25)
        let large = RoomPurpose.listening.rt60Target(volume: 200)
        XCTAssertLessThan(small.upperBound, large.upperBound)
        XCTAssertTrue(RoomPurpose.allCases.contains(.horeca), "HoReCa engine-aware from day one")
        XCTAssertGreaterThan(RoomPurpose.studio.minC80, RoomPurpose.listening.minC80)
    }

    func testUnmeasuredMetricsFallBackToNeutral() {
        var report = makeReport(rt60: 0.4)
        report = AcousticReport(
            bandDecays: [],
            midBandRT60: nil,
            lowToMidDecayRatio: nil,
            c50: nil, c80: nil, d50: nil,
            flutterEcho: nil,
            frequencyResponse: report.frequencyResponse,
            smoothnessDeviationDB: 2,
            lowFrequencyPeaks: [],
            noiseFloor: nil
        )
        let score = ScoreEngine.score(.init(report: report))
        let decay = score.subscores.first { $0.kind == .decay }!
        XCTAssertFalse(decay.isMeasured)
        XCTAssertEqual(decay.value, 50)
    }
}
