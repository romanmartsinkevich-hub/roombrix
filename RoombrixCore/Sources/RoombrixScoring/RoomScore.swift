import Foundation

/// The microphone used for a measurement determines score confidence.
/// Internal mics never show a false-precision single integer.
public enum MicrophoneProfile: String, Sendable, Codable {
    case internalMic
    case calibratedExternal

    /// Half-width of the displayed score range, points.
    public var confidenceHalfWidth: Double {
        switch self {
        case .internalMic: return 3
        case .calibratedExternal: return 1
        }
    }
}

public enum SubscoreKind: String, CaseIterable, Sendable, Codable {
    case decay
    case decayUniformity
    case frequencySmoothness
    case modalSeverity
    case clarity
    case noiseFloor

    /// v1 weights per brief §4.1. Must sum to 1.
    public var weight: Double {
        switch self {
        case .decay: return 0.30
        case .decayUniformity: return 0.15
        case .frequencySmoothness: return 0.20
        case .modalSeverity: return 0.15
        case .clarity: return 0.15
        case .noiseFloor: return 0.05
        }
    }

    public var displayName: String {
        switch self {
        case .decay: return "Decay (RT60)"
        case .decayUniformity: return "Decay uniformity"
        case .frequencySmoothness: return "Frequency response"
        case .modalSeverity: return "Bass modes"
        case .clarity: return "Clarity & reflections"
        case .noiseFloor: return "Noise floor"
        }
    }
}

/// One subscore with its mandatory plain-language explanation.
public struct Subscore: Sendable, Codable {
    public let kind: SubscoreKind
    /// 0–100.
    public let value: Double
    /// One-sentence, jargon-free explanation shown in the UI. Required —
    /// every subscore must be explainable (brief §4.1 rules).
    public let explanation: String
    /// False when the underlying metric could not be measured; the subscore
    /// then falls back to a neutral value and is excluded from diagnosis.
    public let isMeasured: Bool

    public init(kind: SubscoreKind, value: Double, explanation: String, isMeasured: Bool = true) {
        self.kind = kind
        self.value = min(100, max(0, value))
        self.explanation = explanation
        self.isMeasured = isMeasured
    }
}

/// The composite Room Score. Always stored with the algorithm version so
/// historical scores stay comparable across engine updates.
public struct RoomScore: Sendable, Codable {
    /// Composite 0–100 (weighted subscores).
    public let value: Double
    /// Displayed range reflecting microphone confidence, e.g. 62–68.
    public let range: ClosedRange<Double>
    public let subscores: [Subscore]
    public let microphone: MicrophoneProfile
    /// Score-engine version (`score_engine_v`), semver.
    public let engineVersion: String
    public let purpose: RoomPurpose

    public init(
        value: Double,
        subscores: [Subscore],
        microphone: MicrophoneProfile,
        engineVersion: String,
        purpose: RoomPurpose
    ) {
        let clamped = min(100, max(0, value))
        self.value = clamped
        let half = microphone.confidenceHalfWidth
        self.range = max(0, clamped - half)...min(100, clamped + half)
        self.subscores = subscores
        self.microphone = microphone
        self.engineVersion = engineVersion
        self.purpose = purpose
    }
}
