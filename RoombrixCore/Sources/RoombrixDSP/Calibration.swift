import Foundation

/// SINGLE REGISTRY of every empirically tuned constant in the measurement
/// engine, with provenance. When the multi-room validation campaign runs,
/// this file is the checklist of what must survive rooms it was not tuned
/// on — and what may prove overfit to room 1.
///
/// Provenance labels:
/// - `[STANDARD]`   — from ISO 3382 practice or basic DSP; not room-tuned.
/// - `[SYNTHETIC]`  — tuned/validated on synthetic ground-truth signals.
/// - `[ROOM1]`      — PROVISIONAL: calibrated on the 2026-08-29 acceptance
///                    room (domestic listening room, iPhone 15 Plus captures
///                    vs REW + OmniMic reference). Must be re-examined on
///                    every new campaign room.
public enum Calibration {

    // MARK: - Fit-window policy (ReverbTime.adaptiveFit)

    /// Start sits this many dB above the cliff anchor (EDC at direct+5 ms).
    /// [ROOM1] Chosen so the window starts just below the cliff knee:
    /// smaller values ride the cliff (RT short), larger descend into the
    /// noisier mid-curve (RT long, less repeatable).
    public static let cliffAnchorOffsetDB = 3.0

    /// Window starts are quantized to this grid. [ROOM1] Continuous starts
    /// transferred 0.5–1 dB take-to-take anchor differences into 3–4 % RT
    /// spread (local sensitivity 2.5–4 %/dB). Residual risk: anchors on a
    /// grid boundary may flip between takes.
    public static let fitWindowGridDB = 5.0

    /// Where the cliff anchor is read: EDC level this long after the direct
    /// arrival. [ROOM1] A point sample (3–8 ms averaging spanned the knee
    /// and amplified take differences).
    public static let cliffAnchorTimeSeconds = 0.005

    /// Preferred window span below the start. [ROOM1] Span 30 read +16 % at
    /// 500 Hz vs REW; span 20 read −15 % at 1 kHz; 25 passed every band.
    public static let preferredSpanDB = 25.0

    /// Span used when the window starts at −5 dB (clean top): the standard
    /// T30 range. [STANDARD]
    public static let cleanTopSpanDB = 30.0

    /// Below this span no fit is attempted (band → unmeasurable). [STANDARD]
    public static let minimumSpanDB = 15.0

    /// Window ends never go below this level unless the band's usable data
    /// only begins deeper (large direct cliffs keep their span). [ROOM1]
    /// Ends below −43 dB varied 3–4 % between consecutive takes
    /// (non-stationary ambient in the tail); shallower ends ≤ 1.5 %.
    public static let fitWindowEndFloorDB = -43.0

    /// The end floor applies only when it leaves at least this much span.
    /// [ROOM1]
    public static let endFloorMinimumSpanDB = 18.0

    // MARK: - Decay-curve estimation (SchroederIntegration)

    /// Truncation: integration stops where the smoothed level meets
    /// noise + this margin. [SYNTHETIC] (simplified Lundeby)
    public static let noiseTruncationMarginDB = 8.0

    /// Usable range ends this many dB above the empirical noise plateau.
    /// [STANDARD] ISO 3382-2 practice (fit range + 10 dB headroom).
    public static let plateauSafetyMarginDB = 10.0

    /// Usable-range ceiling, dB. [STANDARD] (sanity cap)
    public static let usableRangeCapDB = 90.0

    // MARK: - Sanity gates (ReverbTime / RoomAnalyzer)

    /// No decay metric below this is ever reported — sub-20 ms figures are
    /// direct-pulse artifacts, never rooms. [ROOM1+SYNTHETIC]
    public static let minimumPlausibleDecaySeconds = 0.02

    /// Minimum fit r² for a reported estimate. [SYNTHETIC]
    public static let minimumFitQuality = 0.8

    /// T30/T20 curvature bounds — outside means no single slope. [SYNTHETIC]
    public static let curvatureRatioBounds = 0.5...2.0

    /// Per-band direct-energy dominance (−EDC@5 ms, banded) above which the
    /// capture is flagged. [ROOM1] Healthy 4 kHz reads ~34 dB, the
    /// excessive-level capture ~37 dB — the gate at 45 dB fires only for
    /// genuinely pathological setups; routine level problems are caught by
    /// post-hoc range validation. LIKELY ROOM-DEPENDENT: distance-sensitive.
    public static let perBandDirectGateDB = 45.0

    /// Broadband D/R threshold — informational only. [ROOM1]
    public static let broadbandDirectGateDB = 35.0

    // MARK: - Timing-reference gates (TimingReference)

    /// Peak-to-RMS confidence gate on normalized cross-correlation.
    /// [SYNTHETIC] Flagged for re-tuning on real recordings since Sprint 0;
    /// real captures have read 24–40 dB so far.
    public static let minimumMarkerConfidenceDB = 12.0

    /// Start marker must exceed the median level of the preceding 0.5 s by
    /// this much. [SYNTHETIC]
    public static let minimumPreMarkerQuietDB = 6.0

    /// Marker-spacing drift beyond this is a detection failure, not a clock.
    /// [STANDARD] Consumer clocks sit well under 500 ppm.
    public static let maximumPlausibleDriftPPM = 2_000.0

    // MARK: - Capture-quality targets (app flow)

    /// Pink-noise per-band headroom target. [ROOM1] 27 dB pink SNR gave
    /// 47–57 dB sweep SNR (band concentration + deconvolution gain).
    public static let pinkNoiseTargetSNRdB = 27.0

    /// Peak-to-noise gap below which bass reliability advice is shown.
    /// [STANDARD]
    public static let targetPeakToNoiseGapDB = 40.0
}
