import Foundation
import RoombrixDSP

/// Reverberation-time estimation (T20, T30, EDT) from energy decay curves.
public enum ReverbTime {

    /// Which RT figure a band's conditions support.
    public enum Metric: String, Sendable, Codable {
        case t30, t20, unmeasurable
    }

    public struct BandDecay: Sendable {
        public let centerFrequency: Double
        /// RT60 extrapolated from the -5…-25 dB fit, seconds. nil if the decay
        /// range above noise was insufficient.
        public let t20: Double?
        /// RT60 extrapolated from the -5…-35 dB fit, seconds.
        public let t30: Double?
        /// Early decay time (0…-10 dB fit), seconds.
        public let edt: Double?
        /// Coefficient of determination of the T20 fit. Values well below 1
        /// indicate a bent (non-exponential) decay — often modal behavior.
        public let t20FitQuality: Double?
        /// Coefficient of determination of the T30 fit.
        public let t30FitQuality: Double?
        /// Decay range above the noise floor available in this band, dB.
        public let usableDecayRangeDB: Double?

        public init(
            centerFrequency: Double,
            t20: Double?,
            t30: Double?,
            edt: Double?,
            t20FitQuality: Double?,
            t30FitQuality: Double? = nil,
            usableDecayRangeDB: Double? = nil
        ) {
            self.centerFrequency = centerFrequency
            self.t20 = t20
            self.t30 = t30
            self.edt = edt
            self.t20FitQuality = t20FitQuality
            self.t30FitQuality = t30FitQuality
            self.usableDecayRangeDB = usableDecayRangeDB
        }

        /// Adaptive metric selection (validated on real data: a −43 dB noise
        /// floor leaves only 8 dB margin below the T30 fit endpoint, biasing
        /// T30 long while T20 stays accurate):
        /// ≥ 40 dB usable range → T30; 25–40 dB → T20; below 25 dB the band
        /// is honestly unmeasurable. Without range information (hand-built
        /// values) the legacy T30-preferred order applies.
        public var selectedMetric: Metric {
            guard let range = usableDecayRangeDB else {
                if t30 != nil { return .t30 }
                if t20 != nil { return .t20 }
                return .unmeasurable
            }
            if range >= 40, t30 != nil { return .t30 }
            if range >= 25, t20 != nil { return .t20 }
            return .unmeasurable
        }
    }

    /// RT from a linear fit of the EDC between two levels.
    /// Returns (rt60, r²) or nil when the curve never spans the range.
    /// Public for the validation harness's EDC diagnostics.
    public static func fit(
        curve: SchroederIntegration.DecayCurve,
        from upperDB: Double,
        to lowerDB: Double
    ) -> (rt60: Double, rSquared: Double)? {
        let levels = curve.levelsDB
        guard let startIndex = levels.firstIndex(where: { $0 <= upperDB }),
              let endIndex = levels.firstIndex(where: { $0 <= lowerDB }),
              endIndex > startIndex + 4,
              endIndex <= curve.truncationIndex
        else { return nil }

        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0, sumYY = 0.0
        let n = Double(endIndex - startIndex)
        for i in startIndex..<endIndex {
            let x = Double(i) / curve.sampleRate
            let y = levels[i]
            sumX += x; sumY += y
            sumXY += x * y
            sumXX += x * x
            sumYY += y * y
        }
        let denom = n * sumXX - sumX * sumX
        guard denom > 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        guard slope < 0 else { return nil }

        let ssTot = sumYY - sumY * sumY / n
        let intercept = (sumY - slope * sumX) / n
        var ssRes = 0.0
        for i in startIndex..<endIndex {
            let x = Double(i) / curve.sampleRate
            let r = levels[i] - (slope * x + intercept)
            ssRes += r * r
        }
        let rSquared = ssTot > 0 ? max(0, 1 - ssRes / ssTot) : 1
        return (rt60: -60 / slope, rSquared: rSquared)
    }

    /// Per-band decay analysis of an impulse response.
    public static func analyze(
        _ ir: ImpulseResponse,
        bands: [Double] = OctaveBand.standardCenters
    ) -> [BandDecay] {
        bands.compactMap { center in
            guard center < ir.sampleRate / 2 else { return nil }
            let filtered = OctaveBand.filtered(
                ir.samples, center: center, sampleRate: ir.sampleRate
            )
            let curve = SchroederIntegration.decayCurve(of: filtered, sampleRate: ir.sampleRate)
            let t20Fit = fit(curve: curve, from: -5, to: -25)
            let t30Fit = fit(curve: curve, from: -5, to: -35)
            let edtFit = fit(curve: curve, from: -0.1, to: -10)
            return BandDecay(
                centerFrequency: center,
                t20: t20Fit.map { $0.rt60 },
                t30: t30Fit.map { $0.rt60 },
                edt: edtFit.map { $0.rt60 },
                t20FitQuality: t20Fit.map { $0.rSquared },
                t30FitQuality: t30Fit.map { $0.rSquared },
                usableDecayRangeDB: curve.usableRangeDB
            )
        }
    }

    /// Single RT60 figure per band, chosen by `BandDecay.selectedMetric`
    /// (adaptive: T30 with ≥ 40 dB usable range, T20 with 25–40 dB, nil
    /// below), then gated for honesty:
    /// - Fit quality: each estimate is gated by its OWN fit r² (a clean T20
    ///   must not vouch for a noise-bent T30, or vice versa).
    /// - Curvature: when T20 and T30 diverge wildly (ratio outside 0.5…2)
    ///   the decay is not a single slope — typically a direct-sound cliff
    ///   from a processed capture chain, where a steep, high-r² "fit" of the
    ///   cliff yields confident-looking nonsense like T20 = 0.001 s. No
    ///   single figure is honest there; return nil.
    public static func bestEstimate(
        _ band: BandDecay,
        minimumFitQuality: Double = 0.8
    ) -> Double? {
        if let t20 = band.t20, let t30 = band.t30, t20 > 0 {
            let curvature = t30 / t20
            if curvature > 2 || curvature < 0.5 { return nil }
        }
        switch band.selectedMetric {
        case .t30:
            if let t30 = band.t30, (band.t30FitQuality ?? 1) >= minimumFitQuality {
                return t30
            }
            // T30 conditions met but fit poor — a clean T20 is still honest.
            if let t20 = band.t20, (band.t20FitQuality ?? 1) >= minimumFitQuality {
                return t20
            }
            return nil
        case .t20:
            if let t20 = band.t20, (band.t20FitQuality ?? 1) >= minimumFitQuality {
                return t20
            }
            return nil
        case .unmeasurable:
            return nil
        }
    }

    /// Mid-band RT60 (mean of 500 Hz and 1 kHz), the conventional headline figure.
    public static func midBandRT60(_ bands: [BandDecay]) -> Double? {
        let mids = bands
            .filter { $0.centerFrequency == 500 || $0.centerFrequency == 1_000 }
            .compactMap { bestEstimate($0) }
        guard !mids.isEmpty else { return nil }
        return mids.reduce(0, +) / Double(mids.count)
    }

    /// Low-frequency to mid-band decay ratio (the "boomy bass" indicator).
    /// LF = mean of 63–250 Hz bands, mid = mean of 500 Hz–1 kHz bands.
    public static func lowToMidDecayRatio(_ bands: [BandDecay]) -> Double? {
        let lf = bands
            .filter { $0.centerFrequency <= 250 }
            .compactMap { bestEstimate($0) }
        guard let mid = midBandRT60(bands), mid > 0, !lf.isEmpty else { return nil }
        return (lf.reduce(0, +) / Double(lf.count)) / mid
    }
}
