import Foundation
import RoombrixDSP
import RoombrixValidation

/// The two files the user sends to their playback system. Generated once
/// into Documents (visible in the Files app) and shared from the UI.
/// The sweep layout is identical to the validated
/// `validation/stimulus/roombrix_stimulus_48k.wav`.
enum StimulusPackage {

    static let sampleRate = 48_000.0
    static let pinkDuration = 30.0
    static let sweepDuration = 10.0
    static let peakDBFS = -6.0
    static let trailingSilence = 5.0

    static func pinkSamples() -> [Double] {
        PinkNoise.generate(
            duration: pinkDuration, sampleRate: sampleRate, peakLevelDBFS: peakDBFS
        )
    }

    /// Peak-to-RMS of the generated pink file, dB. Deterministic (seeded
    /// generator), used by the level-continuity check: at an unchanged
    /// volume setting, sweep RMS − pink RMS in the room equals the digital
    /// RMS difference of the two files.
    static let pinkCrestFactorDB: Double = {
        let pink = pinkSamples()
        let peak = pink.map(abs).max() ?? 1
        let rms = (pink.reduce(0) { $0 + $1 * $1 } / Double(pink.count)).squareRoot()
        return 20 * log10(peak / max(rms, 1e-12))
    }()

    /// Ensure both files exist in Documents; returns their URLs.
    static func ensureFiles() throws -> (pink: URL, sweep: URL) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pinkURL = documents.appendingPathComponent("roombrix_pink_noise_48k.wav")
        let sweepURL = documents.appendingPathComponent("roombrix_stimulus_48k.wav")

        if !FileManager.default.fileExists(atPath: pinkURL.path) {
            try WAVFile.writePCM24Mono(samples: pinkSamples(), sampleRate: sampleRate, to: pinkURL)
        }
        if !FileManager.default.fileExists(atPath: sweepURL.path) {
            let sweep = SineSweep(parameters: .init(duration: sweepDuration, sampleRate: sampleRate))
            let marker = TimingReference.makeMarker(sampleRate: sampleRate)
            let stimulus = TimingReference.assembleStimulus(marker: marker, payload: sweep.samples)
            let gain = pow(10.0, peakDBFS / 20)
            let samples = stimulus.map { $0 * gain }
                + [Double](repeating: 0, count: Int(trailingSilence * sampleRate))
            try WAVFile.writePCM24Mono(samples: samples, sampleRate: sampleRate, to: sweepURL)
        }
        return (pinkURL, sweepURL)
    }
}
