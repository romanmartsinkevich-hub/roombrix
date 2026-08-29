import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// AGC/processing verification for the device-quirks table — playback-free
/// (the phone never plays audio, so no test tones from the speaker).
///
/// Protocol: the user loops the pink-noise file at a STEADY volume through
/// their system, then starts this check. The app records 8 s and inspects
/// the level trajectory: with `.measurement` mode genuinely bypassing gain
/// control, 1 s block levels of steady pink noise stay flat within a
/// fraction of a dB. Classic AGC rides the gain down after onset — a
/// monotonic drift of > 1.5 dB flags it.
///
/// Limitation vs a stepped-tone test: constant-level material cannot expose
/// compression *ratio*, only gain-riding over time. Sufficient for the
/// quirks table together with CLI cross-verification of the same recording.
enum DeviceCheck {

    struct Outcome {
        /// 1 s block levels, dB (first block skipped — onset transient).
        let blockLevelsDB: [Double]
        /// Max − min across the retained blocks.
        let driftDB: Double
        let passed: Bool
        let deviceModel: String
        let systemVersion: String
        let sampleRate: Double
        let inputDescription: String

        var reportText: String {
            let blocks = blockLevelsDB.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            return """
            Device check — \(deviceModel), iOS \(systemVersion)
            Input: \(inputDescription) @ \(Int(sampleRate)) Hz
            1 s block levels (dBFS): \(blocks)
            Level drift on steady pink noise: \(String(format: "%.2f", driftDB)) dB
            Gain-riding AGC: \(passed ? "NOT DETECTED (drift ≤ 1.5 dB)" : "SUSPECTED — see quirks table")
            """
        }
    }

    #if canImport(AVFAudio)
    /// Requires the pink noise to be ALREADY playing steadily.
    static func run(engine: AudioMeasurementEngine) async -> Outcome? {
        do {
            _ = try engine.configureSession()
            try engine.startCapture()
        } catch {
            return nil
        }
        try? await Task.sleep(for: .seconds(8))
        let recording = engine.stopCapture()
        let fs = engine.sampleRate
        let blockLength = Int(fs)
        guard recording.count >= 7 * blockLength else { return nil }

        var levels: [Double] = []
        // Skip block 0 (onset/settling), keep the next six.
        for b in 1...6 {
            let start = b * blockLength
            let end = min(start + blockLength, recording.count)
            guard end > start else { break }
            var energy = 0.0
            for i in start..<end { energy += recording[i] * recording[i] }
            levels.append(10 * log10(max(energy / Double(end - start), 1e-14)))
        }
        guard let minLevel = levels.min(), let maxLevel = levels.max() else { return nil }
        let drift = maxLevel - minLevel

        #if canImport(UIKit)
        let model = UIDevice.current.model
        let version = UIDevice.current.systemVersion
        #else
        let model = "unknown"
        let version = "unknown"
        #endif
        return Outcome(
            blockLevelsDB: levels,
            driftDB: drift,
            passed: drift <= 1.5,
            deviceModel: model,
            systemVersion: version,
            sampleRate: fs,
            inputDescription: engine.inputDescription
        )
    }
    #endif
}
