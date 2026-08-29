import Foundation
import RoombrixDSP

/// Reverberation-time estimation (T20, T30, EDT) from energy decay curves.
public enum ReverbTime {

    /// Which RT figure a band's conditions support. `topt` means the
    /// adaptive search placed the fit window below the standard −5 dB start
    /// because the top of the EDC is direct-sound-dominated (loud playback,
    /// close mic) — the value is still the room's decay, read from the
    /// reverberant portion.
    public enum Metric: String, Sendable, Codable {
        case t30, t20, topt, unmeasurable
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
        /// Reverberant decay range available for fitting, dB: from the top
        /// of the LINEAR (reverberant) region down to the noise limit. The
        /// direct-sound region is excluded — peak-above-noise is NOT usable
        /// range (a loud direct pulse once inflated this to 85 dB while the
        /// room's actual decay range was ~35 dB).
        public let usableDecayRangeDB: Double?
        /// Adaptive-window RT60 (the authoritative figure), seconds.
        public let adaptiveRT: Double?
        /// r² of the adaptive fit.
        public let adaptiveFitQuality: Double?
        /// Adaptive window placement, EDC dB (e.g. −25…−55). Reported with
        /// every result so window placement is never silent again.
        public let windowStartDB: Double?
        public let windowEndDB: Double?

        public init(
            centerFrequency: Double,
            t20: Double?,
            t30: Double?,
            edt: Double?,
            t20FitQuality: Double?,
            t30FitQuality: Double? = nil,
            usableDecayRangeDB: Double? = nil,
            adaptiveRT: Double? = nil,
            adaptiveFitQuality: Double? = nil,
            windowStartDB: Double? = nil,
            windowEndDB: Double? = nil
        ) {
            self.centerFrequency = centerFrequency
            self.t20 = t20
            self.t30 = t30
            self.edt = edt
            self.t20FitQuality = t20FitQuality
            self.t30FitQuality = t30FitQuality
            self.usableDecayRangeDB = usableDecayRangeDB
            self.adaptiveRT = adaptiveRT
            self.adaptiveFitQuality = adaptiveFitQuality
            self.windowStartDB = windowStartDB
            self.windowEndDB = windowEndDB
        }

        /// Metric label. With an adaptive fit: window span ≥ 30 dB from a
        /// near-top start → T30; span ≥ 20 dB from a near-top start → T20;
        /// a lowered start (direct-dominated top) → Topt. Hand-built values
        /// without adaptive info fall back to the legacy range thresholds.
        public var selectedMetric: Metric {
            if let adaptiveRT, adaptiveRT > 0,
               let start = windowStartDB, let end = windowEndDB {
                let span = start - end
                if start >= -10 {
                    return span >= 30 ? .t30 : .t20
                }
                return .topt
            }
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

    /// Adaptive fit-window search (Topt-equivalent).
    ///
    /// A fixed −5…−35 dB window silently measures the direct pulse instead
    /// of the room whenever the direct-to-reverberant ratio is high (loud
    /// playback, close mic): observed 4 kHz "T30" of 0.064 s where refitting
    /// the SAME curve at −25…−55 recovered the room's true 0.49 s. This
    /// search tries candidate start levels and spans, and picks the most
    /// linear window with the largest span, preferring starts near the top.
    public static func adaptiveFit(
        curve: SchroederIntegration.DecayCurve
    ) -> (rt60: Double, rSquared: Double, startDB: Double, endDB: Double)? {
        // End limit: 10 dB above the noise plateau (encoded in usableRangeDB
        // as distance from the EDC top).
        let endLimitDB = -curve.usableRangeDB
        var best: (rt60: Double, rSquared: Double, startDB: Double, endDB: Double)?
        var bestScore = (span: 0.0, r2: 0.0, start: -Double.infinity)

        for start in stride(from: -5.0, through: -50.0, by: -5.0) {
            for span in [30.0, 25.0, 20.0] {
                let end = start - span
                guard end >= endLimitDB else { continue }
                guard let candidate = fit(curve: curve, from: start, to: end) else { continue }
                // Score: linear windows first (r² ≥ 0.985), then larger span,
                // then higher (earlier) start. Non-linear candidates only win
                // when nothing linear exists.
                let linear = candidate.rSquared >= 0.985
                let bestLinear = bestScore.r2 >= 0.985
                let better: Bool
                if linear != bestLinear {
                    better = linear
                } else if span != bestScore.span {
                    better = span > bestScore.span
                } else if abs(candidate.rSquared - bestScore.r2) > 0.001 {
                    better = candidate.rSquared > bestScore.r2
                } else {
                    better = start > bestScore.start
                }
                if best == nil || better {
                    best = (candidate.rt60, candidate.rSquared, start, end)
                    bestScore = (span, candidate.rSquared, start)
                }
            }
        }
        return best
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
            let adaptive = adaptiveFit(curve: curve)

            // Reverberant usable range: from the adaptive window's start
            // (top of the linear region) down to the noise limit — never
            // from the direct peak.
            let endLimitDB = -curve.usableRangeDB
            let reverbRange = adaptive.map { max(0, $0.startDB - endLimitDB) }
                ?? max(0, -5 - endLimitDB)

            return BandDecay(
                centerFrequency: center,
                t20: t20Fit.map { $0.rt60 },
                t30: t30Fit.map { $0.rt60 },
                edt: edtFit.map { $0.rt60 },
                t20FitQuality: t20Fit.map { $0.rSquared },
                t30FitQuality: t30Fit.map { $0.rSquared },
                usableDecayRangeDB: reverbRange,
                adaptiveRT: adaptive.map { $0.rt60 },
                adaptiveFitQuality: adaptive.map { $0.rSquared },
                windowStartDB: adaptive.map { $0.startDB },
                windowEndDB: adaptive.map { $0.endDB }
            )
        }
    }

    /// Hard sanity limit: an EDT below this while the room clearly decays
    /// slower is, by definition, a misplaced fit on the direct pulse.
    public static let minimumPlausibleEDT = 0.02

    /// Single RT60 figure per band. The adaptive-window fit is authoritative
    /// (gated by its own r²). Without an adaptive fit, legacy T30/T20
    /// selection applies with the honesty gates:
    /// - Misplaced-fit rule: EDT < 0.02 s alongside a much longer late decay
    ///   can never be a valid result — fail rather than report it.
    /// - Fit quality: each estimate is gated by its OWN fit r².
    /// - Curvature: T20/T30 ratio outside 0.5…2 means no single slope exists.
    public static func bestEstimate(
        _ band: BandDecay,
        minimumFitQuality: Double = 0.8
    ) -> Double? {
        // Authoritative path: the adaptive window.
        if let adaptive = band.adaptiveRT, adaptive > 0 {
            guard (band.adaptiveFitQuality ?? 1) >= minimumFitQuality else { return nil }
            // Misplaced-fit sanity: a sub-20 ms adaptive result alongside a
            // fixed-window value that is much longer means the search still
            // landed on a cliff — refuse.
            if adaptive < minimumPlausibleEDT { return nil }
            return adaptive
        }

        // Legacy path (hand-built values without adaptive info).
        if let edt = band.edt, edt < minimumPlausibleEDT,
           (band.t30 ?? band.t20 ?? 0) > 5 * minimumPlausibleEDT {
            // Direct-pulse cliff at the top of the curve and no adaptive fit
            // to rescue it: by definition a misplaced fit.
            return nil
        }
        if let t20 = band.t20, let t30 = band.t30, t20 > 0 {
            let curvature = t30 / t20
            if curvature > 2 || curvature < 0.5 { return nil }
        }
        switch band.selectedMetric {
        case .t30:
            if let t30 = band.t30, (band.t30FitQuality ?? 1) >= minimumFitQuality {
                return t30
            }
            if let t20 = band.t20, (band.t20FitQuality ?? 1) >= minimumFitQuality {
                return t20
            }
            return nil
        case .t20:
            if let t20 = band.t20, (band.t20FitQuality ?? 1) >= minimumFitQuality {
                return t20
            }
            return nil
        case .topt:
            return nil // topt implies adaptive info; handled above
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
