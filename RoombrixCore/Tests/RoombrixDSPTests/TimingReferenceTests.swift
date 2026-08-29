import XCTest
@testable import RoombrixDSP

/// Deterministic generator for reproducible detector tests.
struct FFTTestsSeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xBADC0FFEE : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

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

    // MARK: - False-lock plausibility gates

    /// Regression for the sweep-lock bug: with raw correlation the detector
    /// located the marker inside the SWEEP (8.4 s late) at 24.5 dB confidence
    /// — a confident false lock. The detector must pick the true marker even
    /// when the sweep is 20+ dB louder and the room is reverberant.
    func testPicksTrueMarkerWhenSweepIs20dBLouder() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(
            sampleRate: fs, duration: 0.1, startFrequency: 500, endFrequency: 4_000, guardInterval: 0.2
        )
        let sweep = SineSweep(parameters: .init(
            startFrequency: 100, endFrequency: 7_000, duration: 2.0, sampleRate: fs
        ))
        // Marker at −22 dB relative to the sweep.
        let stimulus = marker.samples.map { $0 * 0.08 }
            + [Double](repeating: 0, count: Int(0.2 * fs))
            + sweep.samples

        // Reverberant room: exponential-decay noise IR, RT ≈ 0.7 s.
        var rng = FFTTestsSeededGenerator(seed: 9)
        let irLength = Int(0.5 * fs)
        var ir = (0..<irLength).map { i -> Double in
            let t = Double(i) / fs
            return Double.random(in: -1...1, using: &rng) * 0.3 * pow(10, -3 * t / 0.7)
        }
        ir[0] += 1.0
        let wet = FFT.convolve(stimulus, ir)

        // 0.5 s lead-in: enough room for the 0.25 s + 50 ms quiet-precedence window.
        let offset = 8_000
        var recording = [Double](repeating: 0, count: offset + wet.count + 8_000)
        for (i, v) in wet.enumerated() { recording[offset + i] += v }
        for i in 0..<recording.count {
            recording[i] += Double.random(in: -1...1, using: &rng) * 1e-4
        }

        let required = marker.samples.count + Int(0.2 * fs) + sweep.samples.count
        let detection = TimingReference.detect(
            marker: marker, in: recording, requiredTrailingSamples: required
        )
        XCTAssertNotNil(detection)
        assertClose(detection!.markerStartIndex, offset, tolerance: 5)
        XCTAssertGreaterThan(detection!.confidenceDB, TimingReference.minimumConfidenceDB)
        // True start marker follows silence → strong quiet-precedence figure.
        XCTAssertNotNil(detection!.preMarkerQuietDB)
        XCTAssertGreaterThan(detection!.preMarkerQuietDB!, TimingReference.minimumPreMarkerQuietDB)
    }

    func testSearchLimitExcludesPositionsWithoutRoomForStimulus() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.2)
        // Marker placed so close to the end that no sweep could follow it.
        let recordingLength = 40_000
        let lateOffset = recordingLength - marker.samples.count - 100
        var rng = FFTTestsSeededGenerator(seed: 10)
        var recording = (0..<recordingLength).map { _ in
            Double.random(in: -0.01...0.01, using: &rng)
        }
        for (i, v) in marker.samples.enumerated() { recording[lateOffset + i] += v }

        let required = marker.samples.count + Int(0.2 * fs) + 16_000
        let detection = TimingReference.detect(
            marker: marker, in: recording, requiredTrailingSamples: required
        )
        if let detection {
            XCTAssertNotEqual(detection.markerStartIndex, lateOffset,
                              "position without room for the stimulus must not win")
            XCTAssertLessThanOrEqual(detection.markerStartIndex + required, recording.count)
            // Note: a noise-only search region can still show double-digit
            // peak-to-RMS "confidence" — which is exactly why the position
            // and quiet-precedence gates exist and confidence alone is not
            // trusted. No confidence assertion here.
        }
    }

    func testQuietPrecedenceLowWhenMarkerFollowsLoudSignal() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.2)
        var rng = FFTTestsSeededGenerator(seed: 11)
        // Loud noise right up to the marker (recording started mid-signal).
        let offset = 8_000
        var recording = (0..<40_000).map { _ in Double.random(in: -0.02...0.02, using: &rng) }
        for i in 0..<offset { recording[i] = Double.random(in: -0.8...0.8, using: &rng) }
        for (i, v) in marker.samples.enumerated() { recording[offset + i] += v }

        let detection = TimingReference.detect(marker: marker, in: recording)
        XCTAssertNotNil(detection?.preMarkerQuietDB)
        XCTAssertLessThan(detection!.preMarkerQuietDB!, TimingReference.minimumPreMarkerQuietDB,
                          "marker preceded by loud signal must flag low quiet-precedence")
    }

    // MARK: - Clock drift (end marker)

    /// Recording with start and end markers at a controlled spacing.
    private func makeTwoMarkerRecording(
        marker: TimingReference.Marker,
        spacing: Int,
        offset: Int,
        extraSpacing: Int
    ) -> [Double] {
        var rng = SystemRandomNumberGenerator()
        var recording = (0..<(offset + spacing + extraSpacing + marker.samples.count + 4_000))
            .map { _ in Double.random(in: -0.02...0.02, using: &rng) }
        for (i, v) in marker.samples.enumerated() {
            recording[offset + i] += v
            recording[offset + spacing + extraSpacing + i] += v
        }
        return recording
    }

    func testZeroDriftMeasuredAsZero() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.2)
        let payloadCount = 16_000
        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: payloadCount)
        let recording = makeTwoMarkerRecording(marker: marker, spacing: spacing, offset: 3_000, extraSpacing: 0)

        let detection = TimingReference.detect(marker: marker, in: recording, expectedMarkerSpacing: spacing)
        XCTAssertNotNil(detection)
        guard let detection else { return }
        assertClose(detection.markerStartIndex, 3_000, tolerance: 2)
        XCTAssertNotNil(detection.endMarkerStartIndex)
        XCTAssertNotNil(detection.clockDriftPPM)
        XCTAssertEqual(detection.clockDriftPPM!, 0, accuracy: 100, "no drift injected → ~0 ppm")
    }

    func testPositiveDriftMeasured() {
        // End marker arrives 24 samples late over a 24 000-sample spacing:
        // exactly +1000 ppm (playback clock running slow).
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.2)
        let payloadCount = 16_000
        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: payloadCount)
        let extra = 24
        let recording = makeTwoMarkerRecording(marker: marker, spacing: spacing, offset: 3_000, extraSpacing: extra)

        let detection = TimingReference.detect(marker: marker, in: recording, expectedMarkerSpacing: spacing)
        XCTAssertNotNil(detection?.clockDriftPPM)
        let expectedPPM = Double(extra) / Double(spacing) * 1_000_000
        XCTAssertEqual(detection!.clockDriftPPM!, expectedPPM, accuracy: 100)
        // Alignment must still point at the START marker even though both
        // markers correlate almost equally.
        assertClose(detection!.markerStartIndex, 3_000, tolerance: 2)
    }

    func testNoEndMarkerYieldsNilDrift() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.2)
        let payload = [Double](repeating: 0, count: 16_000)
        let stimulus = TimingReference.assembleStimulus(marker: marker, payload: payload)
        var rng = SystemRandomNumberGenerator()
        var recording = (0..<(stimulus.count + 8_000)).map { _ in Double.random(in: -0.02...0.02, using: &rng) }
        for (i, v) in stimulus.enumerated() { recording[2_000 + i] += v }

        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: payload.count)
        let detection = TimingReference.detect(marker: marker, in: recording, expectedMarkerSpacing: spacing)
        XCTAssertNotNil(detection)
        XCTAssertNil(detection!.endMarkerStartIndex, "no end marker in the stimulus")
        XCTAssertNil(detection!.clockDriftPPM)
        // Without the spacing hint, drift fields must also stay nil.
        let plain = TimingReference.detect(marker: marker, in: recording)
        XCTAssertNil(plain!.clockDriftPPM)
    }

    func testAssembledEndMarkerRoundTrip() {
        let fs = 16_000.0
        let marker = TimingReference.makeMarker(sampleRate: fs, duration: 0.1, guardInterval: 0.2)
        let payload = (0..<8_000).map { sin(2 * .pi * 440 * Double($0) / fs) * 0.5 }
        let stimulus = TimingReference.assembleStimulus(marker: marker, payload: payload, includeEndMarker: true)
        let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: payload.count)
        XCTAssertEqual(
            stimulus.count,
            spacing + marker.samples.count,
            "stimulus ends exactly after the end marker"
        )

        var recording = [Double](repeating: 0, count: stimulus.count + 6_000)
        for (i, v) in stimulus.enumerated() { recording[1_500 + i] += v }
        let detection = TimingReference.detect(marker: marker, in: recording, expectedMarkerSpacing: spacing)
        XCTAssertNotNil(detection)
        assertClose(detection!.markerStartIndex, 1_500, tolerance: 2)
        XCTAssertNotNil(detection!.endMarkerStartIndex)
        assertClose(detection!.endMarkerStartIndex!, 1_500 + spacing, tolerance: 2)
        XCTAssertEqual(detection!.clockDriftPPM!, 0, accuracy: 100)
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
