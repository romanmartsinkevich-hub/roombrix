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
        noiseFloor: NoiseFloor.Estimate?
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
            noiseFloor: ambient.flatMap(NoiseFloor.estimate)
        )
    }
}
