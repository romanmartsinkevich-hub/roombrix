import Foundation
import RoombrixDSP
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(UIKit)
import UIKit
#endif

/// AGC/processing verification for the device-quirks table.
///
/// Plays three 1 kHz bursts at −30/−20/−10 dBFS through the speaker while
/// recording. If `.measurement` mode genuinely disables gain control, the
/// recorded levels step by 10 dB (±1.5 dB tolerance). AGC would compress
/// the steps.
enum DeviceCheck {

    struct Outcome {
        let stepDeltas: [Double]     // measured level steps, dB (expect ~10)
        let passed: Bool
        let deviceModel: String
        let systemVersion: String
        let sampleRate: Double
        let inputDescription: String

        /// Row-ready summary for docs/DEVICE_QUIRKS.md.
        var reportText: String {
            let steps = stepDeltas.map { String(format: "%+.1f dB", $0) }.joined(separator: ", ")
            return """
            Device check — \(deviceModel), iOS \(systemVersion)
            Input: \(inputDescription) @ \(Int(sampleRate)) Hz
            Level steps (expected +10 dB each): \(steps)
            AGC disabled: \(passed ? "CONFIRMED" : "NOT CONFIRMED — see quirks table")
            """
        }
    }

    #if canImport(AVFAudio)
    /// Runs the linearity check. Requires an already-configured session.
    static func run(engine: AudioMeasurementEngine) async -> Outcome? {
        let fs = engine.sampleRate
        let burstSeconds = 0.4
        let gapSeconds = 0.3
        let levelsDBFS: [Double] = [-30, -20, -10]

        var stimulus: [Double] = [Double](repeating: 0, count: Int(0.5 * fs))
        var burstStarts: [Int] = []
        for level in levelsDBFS {
            burstStarts.append(stimulus.count)
            let amplitude = pow(10, level / 20)
            for i in 0..<Int(burstSeconds * fs) {
                stimulus.append(sin(2 * .pi * 1_000 * Double(i) / fs) * amplitude)
            }
            stimulus.append(contentsOf: [Double](repeating: 0, count: Int(gapSeconds * fs)))
        }

        do {
            try engine.startCapture()
        } catch {
            return nil
        }
        engine.play(stimulus: stimulus)
        let total = Double(stimulus.count) / fs + 0.5
        try? await Task.sleep(for: .seconds(total))
        let recording = engine.stopCapture()

        // Find playback offset via the loudest burst (correlate against a
        // 1 kHz template is overkill here: RMS envelope suffices).
        guard recording.count > stimulus.count / 2 else { return nil }
        // Level per burst window, assuming capture started before playback:
        // locate the last burst as the recording's peak-energy 0.4 s window.
        let burstLength = Int(burstSeconds * fs)
        var bestStart = 0
        var bestEnergy = -Double.infinity
        let hop = burstLength / 8
        var i = 0
        while i + burstLength <= recording.count {
            var energy = 0.0
            for j in i..<(i + burstLength) { energy += recording[j] * recording[j] }
            if energy > bestEnergy {
                bestEnergy = energy
                bestStart = i
            }
            i += hop
        }
        // bestStart = loudest (last) burst; earlier bursts are at fixed offsets.
        let spacing = burstLength + Int(gapSeconds * fs)
        var levels: [Double] = []
        for k in (0..<levelsDBFS.count).reversed() {
            let start = bestStart - (levelsDBFS.count - 1 - k) * spacing
            guard start >= 0, start + burstLength <= recording.count else { return nil }
            // Trim 50 ms from each edge to skip transients.
            let trim = Int(0.05 * fs)
            var energy = 0.0
            var count = 0
            for j in (start + trim)..<(start + burstLength - trim) {
                energy += recording[j] * recording[j]
                count += 1
            }
            levels.append(10 * log10(max(energy / Double(count), 1e-14)))
        }
        levels.reverse()

        let deltas = zip(levels.dropFirst(), levels).map { $0 - $1 }
        let passed = deltas.allSatisfy { abs($0 - 10) <= 1.5 }

        #if canImport(UIKit)
        let model = UIDevice.current.model
        let version = UIDevice.current.systemVersion
        #else
        let model = "unknown"
        let version = "unknown"
        #endif
        return Outcome(
            stepDeltas: deltas,
            passed: passed,
            deviceModel: model,
            systemVersion: version,
            sampleRate: fs,
            inputDescription: engine.inputDescription
        )
    }
    #endif
}
