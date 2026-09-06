import Foundation

/// 3D point in room coordinates: origin at one floor corner,
/// x along length, y along width, z up.
public struct Point3D: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func distance(to other: Point3D) -> Double {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

/// Room boundary surfaces.
public enum Surface: String, CaseIterable, Sendable, Codable {
    case floor, ceiling
    case wallFront    // x = 0 (typically behind the speakers)
    case wallBack     // x = length
    case wallLeft     // y = 0
    case wallRight    // y = width

    public var opposite: Surface {
        switch self {
        case .floor: return .ceiling
        case .ceiling: return .floor
        case .wallFront: return .wallBack
        case .wallBack: return .wallFront
        case .wallLeft: return .wallRight
        case .wallRight: return .wallLeft
        }
    }
}

/// Rectangular room approximation. RoomPlan scans and manual entry both
/// reduce to this for modal prediction; `irregularityFactor` records how far
/// the real geometry deviates so the UI can hide predictions when the
/// approximation is not trustworthy (open question #4 in the brief).
public struct RoomGeometry: Sendable, Codable {
    /// Meters.
    public var length: Double
    public var width: Double
    public var height: Double
    /// 0 = perfectly rectangular; above `modalPredictionIrregularityLimit`
    /// modal predictions should be suppressed in favor of measured LF data only.
    public var irregularityFactor: Double

    public static let modalPredictionIrregularityLimit = 0.25

    public init(length: Double, width: Double, height: Double, irregularityFactor: Double = 0) {
        precondition(length > 0 && width > 0 && height > 0)
        self.length = length
        self.width = width
        self.height = height
        self.irregularityFactor = irregularityFactor
    }

    public var volume: Double { length * width * height }

    public var totalSurfaceArea: Double {
        2 * (length * width + length * height + width * height)
    }

    public func area(of surface: Surface) -> Double {
        switch surface {
        case .floor, .ceiling: return length * width
        case .wallFront, .wallBack: return width * height
        case .wallLeft, .wallRight: return length * height
        }
    }

    public var modalPredictionIsReliable: Bool {
        irregularityFactor <= Self.modalPredictionIrregularityLimit
    }
}
