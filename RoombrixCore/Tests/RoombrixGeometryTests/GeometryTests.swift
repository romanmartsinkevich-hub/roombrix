import XCTest
@testable import RoombrixGeometry

final class GeometryTests: XCTestCase {

    let room = RoomGeometry(length: 5, width: 4, height: 2.5)

    // MARK: - Modes

    func testFirstAxialModes() {
        let modes = RoomModes.predict(for: room, maxFrequency: 100)

        // f(1,0,0) = 343 / (2 · 5) = 34.3 Hz
        let lengthMode = modes.first { $0.nx == 1 && $0.ny == 0 && $0.nz == 0 }
        XCTAssertNotNil(lengthMode)
        XCTAssertEqual(lengthMode!.frequency, 34.3, accuracy: 0.05)
        XCTAssertEqual(lengthMode!.type, .axial)
        XCTAssertEqual(lengthMode!.drivingAxes, ["length"])

        // f(0,1,0) = 343 / (2 · 4) = 42.875 Hz
        let widthMode = modes.first { $0.nx == 0 && $0.ny == 1 && $0.nz == 0 }
        XCTAssertEqual(widthMode!.frequency, 42.875, accuracy: 0.05)

        // f(0,0,1) = 343 / (2 · 2.5) = 68.6 Hz
        let heightMode = modes.first { $0.nz == 1 && $0.nx == 0 && $0.ny == 0 }
        XCTAssertEqual(heightMode!.frequency, 68.6, accuracy: 0.05)

        // Tangential (1,1,0): (343/2)·√(1/25 + 1/16) = 54.9 Hz
        let tangential = modes.first { $0.nx == 1 && $0.ny == 1 && $0.nz == 0 }
        XCTAssertNotNil(tangential)
        XCTAssertEqual(tangential!.type, .tangential)
        XCTAssertEqual(tangential!.frequency, 171.5 * (1.0 / 25 + 1.0 / 16).squareRoot(), accuracy: 0.05)

        // Sorted ascending, all within limit.
        XCTAssertEqual(modes.map(\.frequency), modes.map(\.frequency).sorted())
        XCTAssertTrue(modes.allSatisfy { $0.frequency <= 100 })
    }

    func testModeMatching() {
        let modes = RoomModes.predict(for: room, maxFrequency: 150)
        let matches = RoomModes.matchPeaks(
            predicted: modes,
            measuredPeakFrequencies: [35.0, 90.0],  // 35 ≈ the 34.3 Hz length mode
            toleranceHz: 3
        )
        XCTAssertTrue(matches.contains { $0.mode.nx == 1 && $0.mode.ny == 0 && $0.mode.nz == 0 })
    }

    func testSchroederFrequency() {
        // f_s = 2000 √(0.5 / 50) = 200 Hz
        XCTAssertEqual(RoomModes.schroederFrequency(rt60: 0.5, volume: 50), 200, accuracy: 0.01)
    }

    // MARK: - Absorption

    func testSabineRelations() {
        let volume = room.volume  // 50 m³
        XCTAssertEqual(volume, 50, accuracy: 1e-9)

        let rt = Absorption.sabineRT60(volume: volume, absorptionSabins: 16.1)
        XCTAssertEqual(rt, 0.5, accuracy: 1e-9)

        let implied = Absorption.impliedAbsorption(volume: volume, rt60: 0.5)
        XCTAssertEqual(implied, 16.1, accuracy: 1e-9)

        // Going from 1.0 s to 0.5 s doubles required absorption.
        let added = Absorption.requiredAddedSabins(volume: volume, measuredRT60: 1.0, targetRT60: 0.5)
        XCTAssertEqual(added, 8.05, accuracy: 1e-9)

        // Already at target → nothing needed.
        XCTAssertEqual(Absorption.requiredAddedSabins(volume: volume, measuredRT60: 0.4, targetRT60: 0.5), 0)
    }

    func testRequiredAreaRejectsIneffectiveMaterial() {
        XCTAssertNil(Absorption.requiredArea(sabins: 10, coefficient: 0.05),
                     "a material with α = 0.05 must never be prescribed")
        XCTAssertEqual(Absorption.requiredArea(sabins: 10, coefficient: 0.8)!, 12.5, accuracy: 1e-9)
    }

    func testQuarterWavelengthHonestyRule() {
        // 5 cm panel: effective only above ~1.7 kHz by the quarter-wave rule.
        XCTAssertEqual(Absorption.lowestEffectiveFrequency(absorberDepth: 0.05), 1_715, accuracy: 1)
        // 20 cm absorber reaches down to ~429 Hz.
        XCTAssertEqual(Absorption.lowestEffectiveFrequency(absorberDepth: 0.20), 428.75, accuracy: 1)
        // Deep bass needs real depth: 86 cm for 100 Hz.
        XCTAssertEqual(Absorption.lowestEffectiveFrequency(absorberDepth: 0.8575), 100, accuracy: 0.5)
    }

    // MARK: - Image source

    func testFloorReflectionSymmetricCase() {
        // Speaker and listener at the same height: the floor bounce lands
        // exactly halfway between them.
        let speaker = Point3D(x: 1, y: 2, z: 1)
        let listener = Point3D(x: 4, y: 2, z: 1)
        let reflections = ImageSource.firstReflections(speaker: speaker, listener: listener, room: room)

        let floor = reflections.first { $0.surface == .floor }
        XCTAssertNotNil(floor)
        XCTAssertEqual(floor!.point.x, 2.5, accuracy: 1e-9)
        XCTAssertEqual(floor!.point.y, 2.0, accuracy: 1e-9)
        XCTAssertEqual(floor!.point.z, 0.0, accuracy: 1e-9)
        // Path via image source at (1, 2, −1): √(3² + 2²) = √13.
        XCTAssertEqual(floor!.pathLength, Double(13).squareRoot(), accuracy: 1e-9)
        XCTAssertGreaterThan(floor!.delayAfterDirectMs, 0)

        // All six surfaces produce a reflection for interior points.
        XCTAssertEqual(reflections.count, 6)
        // Sorted by arrival time.
        let delays = reflections.map(\.delayAfterDirectMs)
        XCTAssertEqual(delays, delays.sorted())
    }

    func testSidewallReflectionCoordinates() {
        let speaker = Point3D(x: 1.5, y: 1.0, z: 1.2)
        let listener = Point3D(x: 3.5, y: 1.0, z: 1.2)
        let reflections = ImageSource.firstReflections(speaker: speaker, listener: listener, room: room)

        // Left wall (y = 0): image at (1.5, −1, 1.2); reflection where y = 0
        // → halfway since both are at y = 1.
        let left = reflections.first { $0.surface == .wallLeft }
        XCTAssertNotNil(left)
        XCTAssertEqual(left!.point.y, 0, accuracy: 1e-9)
        XCTAssertEqual(left!.point.x, 2.5, accuracy: 1e-9)

        let critical = ImageSource.criticalReflections(
            speaker: speaker, listener: listener, room: room, windowMs: 20
        )
        XCTAssertTrue(critical.allSatisfy { $0.delayAfterDirectMs <= 20 })
        XCTAssertFalse(critical.isEmpty)
    }

    func testRoomSurfaceAreas() {
        XCTAssertEqual(room.area(of: .floor), 20)
        XCTAssertEqual(room.area(of: .wallFront), 10)
        XCTAssertEqual(room.area(of: .wallLeft), 12.5)
        XCTAssertEqual(room.totalSurfaceArea, 2 * (20 + 12.5 + 10))
        XCTAssertEqual(Surface.wallLeft.opposite, .wallRight)
        XCTAssertTrue(room.modalPredictionIsReliable)
        let lShaped = RoomGeometry(length: 5, width: 4, height: 2.5, irregularityFactor: 0.4)
        XCTAssertFalse(lShaped.modalPredictionIsReliable)
    }
}
