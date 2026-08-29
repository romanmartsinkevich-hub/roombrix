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
    /// Direct-sound peak vs early reverberant field (RMS 2–10 ms after the
    /// peak), dB. Calibration from real captures: ~21 dB at a correct
    /// playback level, ~60 dB when the level was excessive. Above
    /// `AcousticReport.excessiveDirectToReverbDB` the capture level should
    /// be flagged rather than silently mis-fit.
    public var directToReverberantDB: Double?

    public static let excessiveDirectToReverbDB = 35.0

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
        directToReverberantDB: Double? = nil
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
            directToReverberantDB: directToReverberantDB(primary)
        )
    }

    /// Direct-sound peak vs early reverberant field: peak level minus the
    /// RMS level of the 2–10 ms window after the peak.
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
