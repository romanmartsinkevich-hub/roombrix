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

    /// Adaptive fit window, anchored to the measured cliff depth.
    ///
    /// A fixed −5…−35 dB window silently measures the direct pulse instead
    /// of the room whenever the direct-to-reverberant ratio is high. And
    /// SEARCHING for the window (by fit linearity) proved non-deterministic
    /// on real captures: the EDC is continuously bowed, so RT rises
    /// monotonically with window depth and r² cannot arbitrate — takes
    /// picked different windows and diverged 7–44 %.
    ///
    /// Instead the window is ANCHORED to a physical feature: the EDC level
    /// 5 ms after the direct arrival (`anchorDB`) — how much energy the
    /// direct pulse consumed. The window starts 3 dB above that anchor
    /// (continuous, no grid rounding: grid boundaries flip between takes,
    /// the anchor itself is stable to fractions of a dB), spans 25 dB
    /// (30 dB when the top of the curve is clean), and must end at least
    /// 10 dB above the empirical noise plateau. Calibrated against a REW
    /// reference across 250 Hz–4 kHz: every band within ±15 %.
    public static func adaptiveFit(
        curve: SchroederIntegration.DecayCurve,
        anchorDB: Double?
    ) -> (rt60: Double, rSquared: Double, startDB: Double, endDB: Double)? {
        let endLimitDB = -curve.usableRangeDB

        // Start: 3 dB above the cliff anchor, QUANTIZED to a 5 dB grid.
        // Continuous starts transfer capture-to-capture anchor differences
        // (0.5–1 dB even with the phone untouched) straight into RT at the
        // local sensitivity of ~2.5–4 %/dB — measured 3.8–4.3 % take-to-take
        // spread. The grid absorbs that jitter; both consecutive reference
        // takes land on identical windows in every band. (Residual risk: an
        // anchor sitting exactly on a grid boundary can flip a band's window
        // between takes; anchors are energy ratios stable to well under the
        // 2.5 dB half-cell, so this is rare.)
        var start = min(-5.0, 5.0 * (((anchorDB ?? -5) + 3) / 5.0).rounded())
        if start - 15 < endLimitDB {
            start = min(-5.0, endLimitDB + 15)
        }

        // End: preferred span 25 dB (30 from a clean top), bounded by the
        // noise limit, with a STABILITY FLOOR at −43 dB: on real consecutive
        // captures, windows ending below −43 dB varied 3–4 % take-to-take
        // (non-stationary ambient noise in the tail) while shallower ends
        // stayed within ~1.5 %. Bands whose usable data only begins deep
        // (large direct cliffs, e.g. 4/8 kHz at high playback level) keep
        // their full span — for them the deep region is all there is, and
        // empirically it is stable when the start is jitter-free.
        let preferredSpan: Double = start >= -5.0 ? 30 : 25
        var end = max(start - preferredSpan, endLimitDB)
        if end < -43.0, start - (-43.0) >= 18 {
            end = -43.0
        }
        if start - end >= 15, let candidate = fit(curve: curve, from: start, to: end) {
            return (candidate.rt60, candidate.rSquared, start, end)
        }
        // Fallback for tight or truncated curves: shorter spans.
        for span in [20.0, 15.0] {
            let fallbackEnd = max(start - span, endLimitDB)
            guard start - fallbackEnd >= 14.9 else { continue }
            if let candidate = fit(curve: curve, from: start, to: fallbackEnd) {
                return (candidate.rt60, candidate.rSquared, start, fallbackEnd)
            }
        }
        return nil
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
            // Cliff anchor: EDC level 5 ms after the direct arrival. (A
            // point sample, deliberately: averaging across 3–8 ms spans the
            // cliff knee and amplifies take-to-take shape differences; the
            // grid quantization in adaptiveFit absorbs point-sample jitter.)
            let anchorIndex = min(ir.directIndex + Int(0.005 * ir.sampleRate), curve.levelsDB.count - 1)
            let anchorDB = anchorIndex >= 0 && anchorIndex < curve.truncationIndex
                ? curve.levelsDB[anchorIndex] : nil
            let adaptive = adaptiveFit(curve: curve, anchorDB: anchorDB)

            // Reverberant usable range: from the adaptive window's start
            // (top of the linear region) down to the noise limit — never
            // from the direct peak.
            let endLimitDB = -curve.usableRangeDB
            let reverbRange = adaptive.map { max(0, $0.startDB - endLimitDB) }
                ?? max(0, -5 - endLimitDB)

            // The misplaced-fit sanity rule applies to EVERY decay metric:
            // sub-20 ms figures are direct-pulse artifacts, never rooms.
            // (EDT 0.001–0.013 s was still being reported after the rule
            // was added for RT60 only.)
            func plausible(_ value: Double?) -> Double? {
                value.flatMap { $0 >= minimumPlausibleEDT ? $0 : nil }
            }
            return BandDecay(
                centerFrequency: center,
                t20: plausible(t20Fit.map { $0.rt60 }),
                t30: plausible(t30Fit.map { $0.rt60 }),
                edt: plausible(edtFit.map { $0.rt60 }),
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
