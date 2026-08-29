import Foundation

/// Rectangular-room modal prediction.
public enum RoomModes {

    public static let speedOfSound = 343.0

    public enum ModeType: String, Sendable, Codable {
        case axial, tangential, oblique

        /// Axial modes carry the most energy and matter most for treatment.
        public var severityWeight: Double {
            switch self {
            case .axial: return 1.0
            case .tangential: return 0.5
            case .oblique: return 0.25
            }
        }
    }

    public struct Mode: Sendable, Codable {
        public let frequency: Double
        public let type: ModeType
        /// Mode integers along (length, width, height).
        public let nx: Int
        public let ny: Int
        public let nz: Int

        /// The room dimension(s) driving this mode — used to phrase
        /// plain-language explanations ("front-to-back bass buildup").
        public var drivingAxes: [String] {
            var axes: [String] = []
            if nx > 0 { axes.append("length") }
            if ny > 0 { axes.append("width") }
            if nz > 0 { axes.append("height") }
            return axes
        }
    }

    /// All modes up to `maxFrequency`, sorted by frequency.
    /// f = (c/2) √((nx/L)² + (ny/W)² + (nz/H)²)
    public static func predict(
        for room: RoomGeometry,
        maxFrequency: Double = 300
    ) -> [Mode] {
        let c2 = speedOfSound / 2
        let maxN = { (dim: Double) in
            max(1, Int((maxFrequency / c2 * dim).rounded(.up)))
        }
        var modes: [Mode] = []
        for nx in 0...maxN(room.length) {
            for ny in 0...maxN(room.width) {
                for nz in 0...maxN(room.height) {
                    if nx == 0 && ny == 0 && nz == 0 { continue }
                    let term = pow(Double(nx) / room.length, 2)
                        + pow(Double(ny) / room.width, 2)
                        + pow(Double(nz) / room.height, 2)
                    let f = c2 * term.squareRoot()
                    guard f <= maxFrequency else { continue }
                    let nonZero = [nx, ny, nz].filter { $0 > 0 }.count
                    let type: ModeType = nonZero == 1 ? .axial : (nonZero == 2 ? .tangential : .oblique)
                    modes.append(Mode(frequency: f, type: type, nx: nx, ny: ny, nz: nz))
                }
            }
        }
        return modes.sorted { $0.frequency < $1.frequency }
    }

    /// Schroeder frequency: below this, isolated modes dominate; above it the
    /// room behaves statistically. f_s = 2000 √(RT60 / V).
    public static func schroederFrequency(rt60: Double, volume: Double) -> Double {
        precondition(rt60 > 0 && volume > 0)
        return 2_000 * (rt60 / volume).squareRoot()
    }

    /// Match measured LF peaks against predicted modes within a tolerance.
    /// Confirmed matches drive the modal-severity subscore and the bass
    /// diagnosis; unmatched measured peaks are still reported (real rooms
    /// are not perfect boxes).
    public static func matchPeaks(
        predicted: [Mode],
        measuredPeakFrequencies: [Double],
        toleranceHz: Double = 3
    ) -> [(mode: Mode, measuredFrequency: Double)] {
        var matches: [(Mode, Double)] = []
        for peak in measuredPeakFrequencies {
            if let mode = predicted
                .filter({ abs($0.frequency - peak) <= toleranceHz })
                .min(by: { abs($0.frequency - peak) < abs($1.frequency - peak) }) {
                matches.append((mode, peak))
            }
        }
        return matches
    }
}
