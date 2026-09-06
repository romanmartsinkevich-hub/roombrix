import Foundation
import RoombrixDSP

/// Everything the scoring and diagnosis layers need from one measurement.
public struct AcousticReport: Sendable {
    public var bandDecays: [ReverbTime.BandDecay]
    public var midBandRT60: Double?
    public var lowToMidDecayRatio: Double?
    public var c50: Double?
    public var c80: Double?
    public var d50: Double?
    public var flutterEcho: FlutterEcho.Detection?
    public var frequencyResponse: FrequencyResponse.Curve
    public var smoothnessDeviationDB: Double
    public var lowFrequencyPeaks: [(frequency: Double, prominenceDB: Double)]
    public var noiseFloor: NoiseFloor.Estimate?
    /// Broadband direct-sound peak vs early reverberant field (RMS 2–10 ms
    /// after the peak), dB. INFORMATIONAL ONLY — dominated by LF where D/R
    /// is naturally low (real captures read 3.6–26.5 dB broadband regardless
    /// of capture quality, so a broadband gate can never fire). Gating
    /// happens per band.
    public var directToReverberantDB: Double?
    /// Per-octave-band D/R, the actual capture-quality gate. Calibration
    /// from real 4 kHz data: ~26 dB on the healthy reference capture vs
    /// ~60 dB on the excessive-playback capture that broke the band.
    public var directToReverberantByBand: [(band: Double, ratioDB: Double)]

    /// Threshold for the per-band gate (1–4 kHz; 8 kHz is naturally deep on
    /// phone captures at the listening position). Calibrated on real data:
    /// healthy captures read ~34 dB at 4 kHz, the "excessive-level" capture
    /// ~37 dB — only 3 dB apart, because in a linear chain D/R barely moves
    /// with level; the original 60 dB figure was an artifact of the broken
    /// SNR/plateau estimators. The gate therefore fires only for genuinely
    /// pathological setups (mic at the speaker); routine level problems are
    /// caught by post-hoc range validation instead.
    public static let excessivePerBandDirectToReverbDB = 45.0
    /// Legacy broadband threshold — informational only.
    public static let excessiveDirectToReverbDB = 35.0

    /// True when any 1–4 kHz band exceeds the per-band threshold.
    public var hasExcessiveDirectLevel: Bool {
        directToReverberantByBand.contains {
            (1_000...4_000).contains($0.band)
                && $0.ratioDB > Self.excessivePerBandDirectToReverbDB
        }
    }

    public init(
        bandDecays: [ReverbTime.BandDecay],
        midBandRT60: Double?,
        lowToMidDecayRatio: Double?,
        c50: Double?,
        c80: Double?,
        d50: Double?,
        flutterEcho: FlutterEcho.Detection?,
        frequencyResponse: FrequencyResponse.Curve,
        smoothnessDeviationDB: Double,
        lowFrequencyPeaks: [(frequency: Double, prominenceDB: Double)],
        noiseFloor: NoiseFloor.Estimate?,
        directToReverberantDB: Double? = nil,
        directToReverberantByBand: [(band: Double, ratioDB: Double)] = []
    ) {
        self.bandDecays = bandDecays
        self.midBandRT60 = midBandRT60
        self.lowToMidDecayRatio = lowToMidDecayRatio
        self.c50 = c50
        self.c80 = c80
        self.d50 = d50
        self.flutterEcho = flutterEcho
        self.frequencyResponse = frequencyResponse
        self.smoothnessDeviationDB = smoothnessDeviationDB
        self.lowFrequencyPeaks = lowFrequencyPeaks
        self.noiseFloor = noiseFloor
        self.directToReverberantDB = directToReverberantDB
        self.directToReverberantByBand = directToReverberantByBand
    }
}

/// One-call pipeline: impulse response (+ optional multi-position IRs and
/// ambient capture) → full acoustic report.
public enum RoomAnalyzer {

    /// - Parameters:
    ///   - primary: IR at the main listening position (used for decay,
    ///     clarity, and flutter analysis).
    ///   - additionalPositions: IRs from the multi-point wizard; their
    ///     magnitude curves are power-averaged with the primary for the
    ///     spatially averaged frequency response.
    ///   - ambient: pre-stimulus room-noise capture, if available.
    ///   - calibration: mic correction curve. Applied to the frequency
    ///     response ONLY — decay/clarity metrics are relative time-domain
    ///     measures and are never calibrated (hard rule; see
    ///     MicrophoneCalibration).
    public static func analyze(
        primary: ImpulseResponse,
        additionalPositions: [ImpulseResponse] = [],
        ambient: [Double]? = nil,
        calibration: MicrophoneCalibration? = nil
    ) -> AcousticReport {
        let decays = ReverbTime.analyze(primary)

        var curves = [FrequencyResponse.smoothedMagnitude(of: primary)]
        for ir in additionalPositions {
            curves.append(FrequencyResponse.smoothedMagnitude(of: ir))
        }
        var averaged = FrequencyResponse.spatialAverage(curves) ?? curves[0]
        if let calibration {
            averaged = calibration.applied(to: averaged)
        }

        return AcousticReport(
            bandDecays: decays,
            midBandRT60: ReverbTime.midBandRT60(decays),
            lowToMidDecayRatio: ReverbTime.lowToMidDecayRatio(decays),
            c50: Clarity.c50(primary),
            c80: Clarity.c80(primary),
            d50: Clarity.d50(primary),
            flutterEcho: FlutterEcho.detect(in: primary),
            frequencyResponse: averaged,
            smoothnessDeviationDB: FrequencyResponse.smoothnessDeviation(of: averaged),
            lowFrequencyPeaks: FrequencyResponse.lowFrequencyPeaks(in: averaged),
            noiseFloor: ambient.flatMap(NoiseFloor.estimate),
            directToReverberantDB: directToReverberantDB(primary),
            directToReverberantByBand: directToReverberantByBand(primary)
        )
    }

    /// Per-band direct-energy dominance: −(EDC level 5 ms after the direct
    /// arrival) of the band-filtered response — how many dB of the band's
    /// total energy the direct pulse consumed. This is the quantity that
    /// actually predicts a broken fixed-window fit (the fit window falls
    /// inside the direct pulse). Broadband D/R is dominated by LF and can
    /// never flag an HF-only problem.
    public static func directToReverberantByBand(
        _ ir: ImpulseResponse,
        bands: [Double] = [500, 1_000, 2_000, 4_000, 8_000]
    ) -> [(band: Double, ratioDB: Double)] {
        let fs = ir.sampleRate
        return bands.compactMap { center in
            guard center < fs / 2 else { return nil }
            let banded = OctaveBand.filtered(ir.samples, center: center, sampleRate: fs)
            let curve = SchroederIntegration.decayCurve(of: banded, sampleRate: fs)
            let anchorIndex = min(ir.directIndex + Int(0.005 * fs), curve.levelsDB.count - 1)
            guard anchorIndex >= 0, anchorIndex < curve.truncationIndex else { return nil }
            return (center, -curve.levelsDB[anchorIndex])
        }
    }

    /// Broadband direct-sound level vs early reverberant field: peak level
    /// minus the RMS level of the 2–10 ms window after the peak.
    /// Informational — see `directToReverberantByBand` for the gate.
    public static func directToReverberantDB(_ ir: ImpulseResponse) -> Double? {
        let fs = ir.sampleRate
        let start = ir.directIndex + Int(0.002 * fs)
        let end = min(ir.directIndex + Int(0.010 * fs), ir.samples.count)
        guard end > start + 8 else { return nil }
        var energy = 0.0
        for i in start..<end { energy += ir.samples[i] * ir.samples[i] }
        let rms = (energy / Double(end - start)).squareRoot()
        let peak = abs(ir.samples[ir.directIndex])
        guard rms > 0, peak > 0 else { return nil }
        return 20 * log10(peak / rms)
    }
}
