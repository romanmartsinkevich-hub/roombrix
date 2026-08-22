import Foundation
import RoombrixAcoustics

/// Diffs Roombrix engine output against REW reference data and reports
/// pass/fail against the acceptance criteria in the brief:
/// RT60 within ±15 % of REW in the 500 Hz–2 kHz bands.
public enum ComparisonHarness {

    public struct BandComparison: Sendable {
        public let bandCenter: Double
        public let roombrixRT60: Double?
        public let referenceRT60: Double?
        /// (roombrix − reference) / reference.
        public let relativeError: Double?
        public let withinTolerance: Bool?
    }

    public struct Report: Sendable {
        public let bands: [BandComparison]
        public let tolerance: Double
        /// Acceptance verdict over the criteria bands (500 Hz–2 kHz).
        public let passed: Bool

        public var summary: String {
            var lines: [String] = []
            lines.append("Band (Hz) | Roombrix RT60 | REW RT60 | Error | Status")
            lines.append("----------|---------------|----------|-------|-------")
            for b in bands {
                let ours = b.roombrixRT60.map { String(format: "%.3f s", $0) } ?? "—"
                let ref = b.referenceRT60.map { String(format: "%.3f s", $0) } ?? "—"
                let err = b.relativeError.map { String(format: "%+.1f %%", $0 * 100) } ?? "—"
                let status: String
                switch b.withinTolerance {
                case .some(true): status = "PASS"
                case .some(false): status = "FAIL"
                case .none: status = "n/a"
                }
                lines.append(String(
                    format: "%9.0f | %13@ | %8@ | %5@ | %@",
                    b.bandCenter, ours as NSString, ref as NSString, err as NSString, status
                ))
            }
            lines.append(passed
                ? "RESULT: PASS (all criteria bands within ±\(Int(tolerance * 100)) %)"
                : "RESULT: FAIL")
            return lines.joined(separator: "\n")
        }
    }

    /// Bands the acceptance criteria are evaluated on.
    public static let criteriaBands: ClosedRange<Double> = 500...2_000

    public static func compareRT60(
        roombrix: [ReverbTime.BandDecay],
        reference: [REWImport.RT60Row],
        tolerance: Double = 0.15
    ) -> Report {
        var comparisons: [BandComparison] = []
        var allCriteriaPassed = true
        var criteriaEvaluated = false

        for decay in roombrix {
            let ours = ReverbTime.bestEstimate(decay)
            // Match reference band within a third-octave of our center.
            let ref = reference
                .filter { $0.bandCenter > 0 }
                .min { abs(log2($0.bandCenter / decay.centerFrequency)) < abs(log2($1.bandCenter / decay.centerFrequency)) }
                .flatMap { row -> Double? in
                    guard abs(log2(row.bandCenter / decay.centerFrequency)) < 0.2 else { return nil }
                    return row.t30 ?? row.t20 ?? row.edt
                }

            var relativeError: Double?
            var within: Bool?
            if let ours, let ref, ref > 0 {
                let err = (ours - ref) / ref
                relativeError = err
                within = abs(err) <= tolerance
                if criteriaBands.contains(decay.centerFrequency) {
                    criteriaEvaluated = true
                    if within == false { allCriteriaPassed = false }
                }
            }
            comparisons.append(BandComparison(
                bandCenter: decay.centerFrequency,
                roombrixRT60: ours,
                referenceRT60: ref,
                relativeError: relativeError,
                withinTolerance: within
            ))
        }

        return Report(
            bands: comparisons,
            tolerance: tolerance,
            passed: criteriaEvaluated && allCriteriaPassed
        )
    }
}
