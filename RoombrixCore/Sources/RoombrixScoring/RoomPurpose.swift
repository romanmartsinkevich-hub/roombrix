import Foundation

/// Room purposes carry their own acoustic targets. HoReCa is included in the
/// enum from day one (per brief §3) but has no UI in MVP.
public enum RoomPurpose: String, CaseIterable, Sendable, Codable {
    case listening
    case studio
    case homeTheater
    case horeca

    /// Target mid-band RT60 range (seconds) for a reference volume of ~50 m³.
    /// The engine scales the target with room volume (larger rooms may
    /// legitimately decay longer).
    var baseRT60Target: ClosedRange<Double> {
        switch self {
        case .listening: return 0.30...0.50
        case .studio: return 0.20...0.35
        case .homeTheater: return 0.25...0.40
        case .horeca: return 0.40...0.80  // speech-intelligibility driven
        }
    }

    /// Volume-scaled RT60 target. Scaling follows a gentle cube-root law:
    /// doubling volume raises the target range by ~26 %.
    public func rt60Target(volume: Double) -> ClosedRange<Double> {
        let reference = 50.0
        let scale = pow(max(volume, 10) / reference, 1.0 / 3.0)
        let base = baseRT60Target
        return (base.lowerBound * scale)...(base.upperBound * scale)
    }

    /// Maximum acceptable LF/mid decay ratio before the uniformity subscore
    /// starts penalizing (brief: < 1.5 for listening rooms).
    public var maxDecayRatio: Double {
        switch self {
        case .listening: return 1.5
        case .studio: return 1.3
        case .homeTheater: return 1.5
        case .horeca: return 1.8
        }
    }

    /// Minimum acceptable C80 (music clarity) in dB.
    public var minC80: Double {
        switch self {
        case .listening, .homeTheater: return 0
        case .studio: return 2
        case .horeca: return -2
        }
    }
}
