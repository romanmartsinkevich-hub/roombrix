import XCTest
@testable import RoombrixDiagnosis
@testable import RoombrixAcoustics
@testable import RoombrixGeometry
@testable import RoombrixScoring
import RoombrixDSP

final class DiagnosisEngineTests: XCTestCase {

    func makeReport(
        rt60: Double,
        lfRatio: Double = 1.0,
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
            c50: c80 - 2, c80: c80, d50: 0.7,
            flutterEcho: flutter,
            frequencyResponse: .init(frequencies: [100, 1_000], levelsDB: [0, 0]),
            smoothnessDeviationDB: 3,
            lowFrequencyPeaks: peaks,
            noiseFloor: nil
        )
    }

    let geometry = RoomGeometry(length: 5, width: 4, height: 2.5)

    func testHealthyRoomHasNoProblems() {
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(rt60: 0.4), geometry: geometry
        ))
        XCTAssertTrue(diagnosis.problems.isEmpty)
        XCTAssertTrue(diagnosis.recommendations.isEmpty)
    }

    func testExcessiveDecayProducesAbsorptionPlan() {
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(rt60: 1.2), geometry: geometry
        ))
        let problem = diagnosis.problems.first { $0.kind == .excessiveDecay }
        XCTAssertNotNil(problem)

        let rec = diagnosis.recommendations.first { $0.problem == .excessiveDecay }
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec!.treatment, .broadbandAbsorber10cm)
        XCTAssertNotNil(rec!.areaSquareMeters)
        XCTAssertGreaterThan(rec!.areaSquareMeters!, 0)
        XCTAssertFalse(rec!.rationale.isEmpty)
        XCTAssertGreaterThan(rec!.predictedScoreImpact.upperBound, 0)
    }

    func testBassProblemIsHonest() {
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(rt60: 0.45, lfRatio: 2.0, peaks: [(34, 10)]),
            geometry: geometry
        ))
        let problem = diagnosis.problems.first { $0.kind == .bassDecayImbalance }
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem!.explanation.contains("standing wave"),
                      "34 Hz peak matches the predicted length mode of a 5 m room")

        let bassRecs = diagnosis.recommendations.filter { $0.problem == .bassDecayImbalance }
        XCTAssertEqual(bassRecs.count, 2)

        // Zero-cost positional advice must come before purchases.
        let first = bassRecs.min { $0.priority < $1.priority }!
        XCTAssertNil(first.treatment)
        XCTAssertEqual(first.costTier, .free)

        // The physical treatment must have real low-frequency depth,
        // and the rationale must carry the honesty language.
        let physical = bassRecs.first { $0.treatment != nil }!
        XCTAssertTrue(DiagnosisEngine.isValidBassTreatment(physical.treatment!))
        XCTAssertGreaterThanOrEqual(physical.treatment!.depth, 0.20)
        XCTAssertTrue(physical.rationale.contains("Thin decorative panels will NOT fix bass"))
        XCTAssertTrue(physical.rationale.contains("DSP"), "DSP mentioned as complementary")
    }

    func testThinPanelsAreNeverValidBassTreatments() {
        XCTAssertFalse(DiagnosisEngine.isValidBassTreatment(.broadbandAbsorber5cm))
        XCTAssertFalse(DiagnosisEngine.isValidBassTreatment(.broadbandAbsorber10cm))
        XCTAssertFalse(DiagnosisEngine.isValidBassTreatment(.thickCurtain))
        XCTAssertFalse(DiagnosisEngine.isValidBassTreatment(.rug))
        XCTAssertTrue(DiagnosisEngine.isValidBassTreatment(.cornerBassTrap))
        XCTAssertTrue(DiagnosisEngine.isValidBassTreatment(.broadbandAbsorber20cm))
    }

    func testEarlyReflectionsUseImageSourcePoints() {
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(rt60: 0.45, c80: -3),
            geometry: geometry,
            purpose: .listening,
            speakerPositions: [Point3D(x: 1, y: 1, z: 1.1), Point3D(x: 1, y: 3, z: 1.1)],
            listenerPosition: Point3D(x: 3.5, y: 2, z: 1.1)
        ))
        let rec = diagnosis.recommendations.first { $0.problem == .earlyReflections }
        XCTAssertNotNil(rec)
        XCTAssertFalse(rec!.placement.points.isEmpty, "exact wall coordinates from image-source calc")
        XCTAssertFalse(rec!.placement.surfaces.contains(.floor), "floor bounce excluded (rug handled elsewhere)")
        for point in rec!.placement.points {
            XCTAssertTrue(point.x >= 0 && point.x <= geometry.length)
            XCTAssertTrue(point.y >= 0 && point.y <= geometry.width)
            XCTAssertTrue(point.z >= 0 && point.z <= geometry.height)
        }
    }

    func testFlutterIdentifiesWallPair() {
        // Spacing 4.0 m ≈ room width → left/right wall pair.
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(
                rt60: 0.45,
                flutter: .init(period: 0.0233, surfaceSpacing: 4.0, strength: 0.4)
            ),
            geometry: geometry
        ))
        let problem = diagnosis.problems.first { $0.kind == .flutterEcho }
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem!.explanation.contains("left and right walls"))

        let rec = diagnosis.recommendations.first { $0.problem == .flutterEcho }
        XCTAssertNotNil(rec)
        XCTAssertEqual(Set(rec!.placement.surfaces), Set([.wallLeft, .wallRight]))
        XCTAssertTrue(rec!.placement.description.contains("ONE side"))
    }

    func testOverdampedRoomGetsDiffusionNotAbsorption() {
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(rt60: 0.15), geometry: geometry
        ))
        let problem = diagnosis.problems.first { $0.kind == .overdamped }
        XCTAssertNotNil(problem)
        let rec = diagnosis.recommendations.first { $0.problem == .overdamped }
        XCTAssertEqual(rec?.treatment, .diffuser)
    }

    func testTopProblemOrderingAndFreeTierGate() {
        let diagnosis = DiagnosisEngine.diagnose(.init(
            report: makeReport(rt60: 1.6, lfRatio: 2.2, c80: -2, peaks: [(34, 12)]),
            geometry: geometry
        ))
        XCTAssertGreaterThanOrEqual(diagnosis.problems.count, 3)
        XCTAssertNotNil(diagnosis.topProblem)
        // Problems sorted by severity; recommendations by priority.
        let severities = diagnosis.problems.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >))
        let priorities = diagnosis.recommendations.map(\.priority)
        XCTAssertEqual(priorities, priorities.sorted())
        // Every recommendation carries the required fields (brief §5.4).
        for rec in diagnosis.recommendations {
            XCTAssertFalse(rec.rationale.isEmpty)
            XCTAssertFalse(rec.placement.description.isEmpty)
            XCTAssertGreaterThanOrEqual(rec.predictedScoreImpact.lowerBound, 0)
        }
    }

    func testProductSchemaHasCommissionFields() {
        // Phase-2 fields exist now so vendor catalogs plug in without schema changes.
        let product = Product(
            id: "gik-244",
            treatmentType: .broadbandAbsorber10cm,
            name: "244 Bass Trap",
            vendor: "GIK Acoustics",
            affiliateURL: "https://example.com/ref",
            commission: 0.08
        )
        XCTAssertEqual(product.commission, 0.08)
        XCTAssertNotNil(product.affiliateURL)
        XCTAssertEqual(product.treatmentType.absorption.value(at: 1_000), 1.0)
    }
}
