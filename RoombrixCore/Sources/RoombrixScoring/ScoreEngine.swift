import Foundation
import RoombrixAcoustics
import RoombrixGeometry

/// Room Score v1: deterministic, explainable, versioned.
public enum ScoreEngine {

    /// Bump on any change that alters scores; stored with every measurement.
    public static let version = "1.0.0"

    public struct Input: Sendable {
        public var report: AcousticReport
        /// Optional — scoring works without geometry (modal subscore then
        /// relies on measured peaks alone).
        public var geometry: RoomGeometry?
        public var purpose: RoomPurpose
        public var microphone: MicrophoneProfile

        public init(
            report: AcousticReport,
            geometry: RoomGeometry? = nil,
            purpose: RoomPurpose = .listening,
            microphone: MicrophoneProfile = .internalMic
        ) {
            self.report = report
            self.geometry = geometry
            self.purpose = purpose
            self.microphone = microphone
        }
    }

    public static func score(_ input: Input) -> RoomScore {
        let subscores = [
            decaySubscore(input),
            uniformitySubscore(input),
            smoothnessSubscore(input),
            modalSubscore(input),
            claritySubscore(input),
            noiseSubscore(input),
        ]
        var composite = 0.0
        for s in subscores {
            composite += s.value * s.kind.weight
        }
        return RoomScore(
            value: composite,
            subscores: subscores,
            microphone: input.microphone,
            engineVersion: version,
            purpose: input.purpose
        )
    }

    // MARK: - Decay (30 %)

    static func decaySubscore(_ input: Input) -> Subscore {
        let volume = input.geometry?.volume ?? 50
        let target = input.purpose.rt60Target(volume: volume)
        let bands = input.report.bandDecays.filter {
            OctaveBand125to4k.contains($0.centerFrequency)
        }
        var penalties: [Double] = []
        for band in bands {
            guard let rt = ReverbTime.bestEstimate(band) else { continue }
            // Tolerance widens at LF (brief §4.1): ×1.5 below 250 Hz.
            let widen = band.centerFrequency < 250 ? 1.5 : 1.0
            let lo = target.lowerBound / widen
            let hi = target.upperBound * widen
            let deviation: Double
            if rt > hi {
                deviation = (rt - hi) / hi
            } else if rt < lo {
                deviation = (lo - rt) / lo
            } else {
                deviation = 0
            }
            penalties.append(deviation)
        }
        guard !penalties.isEmpty, let mid = input.report.midBandRT60 else {
            return Subscore(
                kind: .decay,
                value: 50,
                explanation: "We could not measure decay reliably — try a louder sweep or a quieter room.",
                isMeasured: false
            )
        }
        let meanPenalty = penalties.reduce(0, +) / Double(penalties.count)
        // 100 % relative deviation = zero points.
        let value = 100 * max(0, 1 - meanPenalty)
        let explanation: String
        if meanPenalty == 0 {
            explanation = String(
                format: "Sound decays in about %.2f s — right in the ideal range for this room.",
                mid
            )
        } else if mid > target.upperBound {
            explanation = String(
                format: "Sound lingers for about %.2f s — longer than the ideal %.2f–%.2f s, which blurs detail.",
                mid, target.lowerBound, target.upperBound
            )
        } else {
            explanation = String(
                format: "Sound dies away in %.2f s — shorter than ideal (%.2f–%.2f s), which can feel lifeless.",
                mid, target.lowerBound, target.upperBound
            )
        }
        return Subscore(kind: .decay, value: value, explanation: explanation)
    }

    static let OctaveBand125to4k: ClosedRange<Double> = 125...4_000

    // MARK: - Decay uniformity (15 %)

    static func uniformitySubscore(_ input: Input) -> Subscore {
        guard let ratio = input.report.lowToMidDecayRatio else {
            return Subscore(
                kind: .decayUniformity,
                value: 50,
                explanation: "Low-frequency decay could not be measured in this capture.",
                isMeasured: false
            )
        }
        let limit = input.purpose.maxDecayRatio
        // Full marks at ratio ≤ 1.1; zero at ratio ≥ limit + 1.
        let value: Double
        if ratio <= 1.1 {
            value = 100
        } else {
            value = 100 * max(0, 1 - (ratio - 1.1) / (limit - 0.1))
        }
        let explanation: String
        if ratio > limit {
            explanation = String(
                format: "Your bass rings about %.1f× longer than your midrange — this is why bass sounds boomy and slow.",
                ratio
            )
        } else {
            explanation = "Bass and midrange decay at a similar rate — the room sounds even across frequencies."
        }
        return Subscore(kind: .decayUniformity, value: value, explanation: explanation)
    }

    // MARK: - Frequency-response smoothness (20 %)

    static func smoothnessSubscore(_ input: Input) -> Subscore {
        let deviation = input.report.smoothnessDeviationDB
        // ≤ 2 dB weighted deviation is excellent; ≥ 8 dB is severe.
        let value = 100 * max(0, min(1, (8 - deviation) / 6))
        let explanation: String
        if deviation <= 3 {
            explanation = "The tonal balance is fairly even from bass through treble."
        } else {
            explanation = String(
                format: "Levels swing about ±%.0f dB across the range — some notes jump out while others disappear.",
                deviation
            )
        }
        return Subscore(kind: .frequencySmoothness, value: value, explanation: explanation)
    }

    // MARK: - Modal severity (15 %)

    static func modalSubscore(_ input: Input) -> Subscore {
        let peaks = input.report.lowFrequencyPeaks
        guard !peaks.isEmpty else {
            return Subscore(
                kind: .modalSeverity,
                value: 95,
                explanation: "No strong isolated bass peaks detected at the listening position."
            )
        }
        // Cross-check against predicted modes when reliable geometry exists.
        var confirmedByGeometry = false
        if let geometry = input.geometry,
           geometry.modalPredictionIsReliable,
           let rt = input.report.midBandRT60 {
            let schroeder = RoomModes.schroederFrequency(rt60: rt, volume: geometry.volume)
            let predicted = RoomModes.predict(for: geometry, maxFrequency: max(schroeder, 120))
            let matches = RoomModes.matchPeaks(
                predicted: predicted,
                measuredPeakFrequencies: peaks.map { $0.frequency }
            )
            confirmedByGeometry = !matches.isEmpty
        }
        // Penalty grows with count and prominence of isolated LF peaks.
        var penalty = 0.0
        for peak in peaks {
            penalty += min(peak.prominenceDB, 15) / 15 * 25
        }
        let value = max(0, 100 - penalty)
        let strongest = peaks.max { $0.prominenceDB < $1.prominenceDB }!
        var explanation = String(
            format: "Bass peaks around %.0f Hz stand about %.0f dB above their surroundings — certain notes will boom.",
            strongest.frequency, strongest.prominenceDB
        )
        if confirmedByGeometry {
            explanation += " Your room dimensions predict a standing wave at this frequency."
        }
        return Subscore(kind: .modalSeverity, value: value, explanation: explanation)
    }

    // MARK: - Clarity / early reflections (15 %)

    static func claritySubscore(_ input: Input) -> Subscore {
        guard let c80 = input.report.c80 else {
            return Subscore(
                kind: .clarity,
                value: 50,
                explanation: "Clarity could not be computed from this capture.",
                isMeasured: false
            )
        }
        let minimum = input.purpose.minC80
        // Full marks at minC80 + 6 dB; zero at minC80 − 6 dB.
        var value = 100 * max(0, min(1, (c80 - (minimum - 6)) / 12))
        var explanation: String
        if c80 >= minimum {
            explanation = String(
                format: "Direct sound clearly dominates reflections (C80 = %.1f dB) — imaging should be stable.",
                c80
            )
        } else {
            explanation = String(
                format: "Reflections arrive nearly as loud as the direct sound (C80 = %.1f dB) — the sound stage smears.",
                c80
            )
        }
        if let flutter = input.report.flutterEcho {
            value = max(0, value - 15 * flutter.strength / 0.5)
            explanation += String(
                format: " A flutter echo bounces between surfaces about %.1f m apart.",
                flutter.surfaceSpacing
            )
        }
        return Subscore(kind: .clarity, value: value, explanation: explanation)
    }

    // MARK: - Noise floor (5 %, informational)

    static func noiseSubscore(_ input: Input) -> Subscore {
        guard let noise = input.report.noiseFloor else {
            return Subscore(
                kind: .noiseFloor,
                value: 70,
                explanation: "Background noise was not captured in this measurement.",
                isMeasured: false
            )
        }
        let value: Double
        switch noise.levelDBFS {
        case ..<(-70): value = 100
        case ..<(-55): value = 85
        case ..<(-40): value = 60
        default: value = 30
        }
        return Subscore(
            kind: .noiseFloor,
            value: value,
            explanation: "Background noise level: \(noise.descriptor) (phone-mic estimate, not a lab measurement)."
        )
    }
}
