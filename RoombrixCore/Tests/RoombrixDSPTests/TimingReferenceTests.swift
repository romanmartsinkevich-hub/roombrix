import XCTest
@testable import RoombrixDSP

final class TimingReferenceTests: XCTestCase {

    func testDetectsMarkerAtKnownOffsetInNoise() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(
            sampleRate: fs, duration: 0.1, startFrequency: 500, endFrequency: 4_000, guardInterval: 0.2
        )

        var rng = SystemRandomNumberGenerator()
        let offset = 5_432
        var recording = (0..<40_000).map { _ in Double.random(in: -0.05...0.05, using: &rng) }
        for (i, v) in marker.samples.enumerated() {
            recording[offset + i] += v * 0.5  // marker at −6 dB into noise
        }

        let detection = TimingReference.detect(marker: marker, in: recording)
        XCTAssertNotNil(detection)
        guard let detection else { return }
        assertClose(detection.markerStartIndex, offset, tolerance: 2)
        XCTAssertGreaterThan(detection.confidenceDB, TimingReference.minimumConfidenceDB)
        XCTAssertEqual(
            detection.stimulusStartIndex,
            detection.markerStartIndex + marker.samples.count + Int(marker.guardInterval * fs)
        )
    }

    func testLowConfidenceOnPureNoise() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1)
        var rng = SystemRandomNumberGenerator()
        let recording = (0..<40_000).map { _ in Double.random(in: -0.5...0.5, using: &rng) }

        let detection = TimingReference.detect(marker: marker, in: recording)
        XCTAssertNotNil(detection)
        // Detection exists but must not clear the confidence bar.
        XCTAssertLessThan(detection!.confidenceDB, TimingReference.minimumConfidenceDB + 6)
    }

    func testAssembleStimulusLayout() {
        let fs = 8_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.5)
        let payload = [Double](repeating: 0.7, count: 100)
        let stimulus = TimingReference.assembleStimulus(marker: marker, payload: payload)
        XCTAssertEqual(stimulus.count, marker.samples.count + Int(0.5 * fs) + payload.count)
        XCTAssertEqual(stimulus.last, 0.7)
    }

    private func assertClose(_ a: Int, _ b: Int, tolerance: Int) {
        XCTAssertLessThanOrEqual(abs(a - b), tolerance, "\(a) not within \(tolerance) of \(b)")
    }
}
