import Foundation
import RoombrixAcoustics
import RoombrixDSP
import RoombrixValidation

// roombrix-validate — CLI validation harness.
//
// Commands:
//
//   measure <recording> [--rew <rt60-export.txt>] [--duration 10]
//       Full pipeline on a RAW recording of the played stimulus:
//       sanity checks (clipping, length, marker confidence, SNR) →
//       alignment → deconvolution → per-band EDT/T20/T30 → optional REW diff
//       (pass/fail over 250 Hz–4 kHz, informational below 250 Hz).
//       Accepts WAV natively; .aifc/.m4a (ALAC)/.aiff/.caf/.flac are decoded
//       losslessly via ffmpeg (or afconvert on macOS).
//
//   rt60 <ir.wav> [--rew <rt60-export.txt>]
//       Analyze an already-deconvolved impulse response.
//
//   stimulus <output.wav> [--duration 10] [--rate 48000] [--bits 24]
//            [--tail 5] [--peak-dbfs -6] [--end-marker]
//       Export the measurement stimulus (timing marker + guard + ESS sweep
//       [+ end marker] + trailing silence).
//
//   edc <recording> --band <Hz> [--duration 10]
//       Decay-curve diagnostics for one octave band of a raw recording:
//       noise floor, truncation point, and T20/T30 under different noise
//       margins — for pinning down why two implementations disagree.
//
// Exit codes: 0 = OK/PASS, 1 = error or refused input, 2 = REW diff FAIL.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
    exit(1)
}

func flagValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hasFlag(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

func printDecayTable(_ decays: [ReverbTime.BandDecay]) {
    print("Band (Hz) |   EDT   |   T20   |   T30   |  fit r²")
    print("----------|---------|---------|---------|--------")
    for d in decays {
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f s", $0) } ?? "   —   " }
        let quality = d.t20FitQuality.map { String(format: "%.3f", $0) } ?? "  —  "
        print(String(format: "%9.0f | %@ | %@ | %@ | %@",
                     d.centerFrequency, fmt(d.edt), fmt(d.t20), fmt(d.t30), quality))
    }
}

func runREWComparison(
    decays: [ReverbTime.BandDecay],
    rewPath: String,
    criteriaBands: ClosedRange<Double>
) -> Never {
    let text: String
    do {
        text = try String(contentsOfFile: rewPath, encoding: .utf8)
    } catch {
        fail("Could not read REW export \(rewPath): \(error)")
    }
    do {
        let reference = try REWImport.parseRT60(text: text)
        let report = ComparisonHarness.compareRT60(
            roombrix: decays, reference: reference, criteriaBands: criteriaBands
        )
        print("\n=== REW comparison (criteria: \(Int(criteriaBands.lowerBound))–\(Int(criteriaBands.upperBound)) Hz, ±\(Int(report.tolerance * 100)) %) ===")
        print(report.summary)
        exit(report.passed ? 0 : 2)
    } catch {
        fail("Could not parse REW RT60 export \(rewPath): \(error)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("""
    Usage:
      roombrix-validate measure <recording.wav|.aifc|.m4a> [--rew <rt60-export.txt>] [--duration 10]
      roombrix-validate rt60 <ir.wav|.aifc|.m4a> [--rew <rt60-export.txt>]
      roombrix-validate stimulus <output.wav> [--duration 10] [--rate 48000] [--bits 24] [--tail 5] [--peak-dbfs -6] [--end-marker]
    """)
}

switch command {
case "measure":
    guard args.count >= 2 else { fail("measure: missing <recording> argument") }
    let url = URL(fileURLWithPath: args[1])
    let sweepDuration = flagValue("--duration", in: args).flatMap(Double.init) ?? 10

    let audio: WAVFile.Audio
    do {
        audio = try AudioLoader.load(url: url)
    } catch {
        fail("Could not read \(url.path): \(error)")
    }
    if url.pathExtension.lowercased() != "wav" {
        print("Input .\(url.pathExtension.lowercased()) decoded losslessly to PCM for analysis.")
    }
    let fs = audio.sampleRate
    let recording = audio.samples

    print("Recording: \(recording.count) samples @ \(Int(fs)) Hz (\(String(format: "%.1f", Double(recording.count) / fs)) s), first channel used")
    if fs != 48_000 {
        print("Note: recording is not 48 kHz — processing at the native rate of \(Int(fs)) Hz (this is fine).")
    }
    if fs < 44_100 {
        fail("Sample rate \(Int(fs)) Hz is below 44.1 kHz. Record at 44.1 or 48 kHz and try again.")
    }

    // --- Clipping check -----------------------------------------------------
    let clippedCount = recording.lazy.filter { abs($0) >= 0.99 }.count
    if clippedCount > 10 {
        fail("""
        Clipping detected: \(clippedCount) samples at or near full scale.
        The recording level was too high — the measurement would be distorted.
        Lower the recording (input) level, NOT the playback volume, and record again.
        """)
    }
    print("Clipping check: OK (\(clippedCount) near-full-scale samples)")

    // --- Rebuild the stimulus DSP at the recording's native rate ------------
    // The analog stimulus is rate-independent; regenerating sweep and marker
    // at the capture rate makes deconvolution exact without resampling.
    let sweep = SineSweep(parameters: .init(
        startFrequency: 20, endFrequency: 20_000, duration: sweepDuration, sampleRate: fs
    ))
    let marker = TimingReference.makeMarker(sampleRate: fs)

    // --- Length check --------------------------------------------------------
    let guardSamples = Int(marker.guardInterval * fs)
    let minimumSamples = marker.samples.count + guardSamples + sweep.samples.count + Int(3 * fs)
    if recording.count < minimumSamples {
        fail("""
        Recording too short: \(String(format: "%.1f", Double(recording.count) / fs)) s, \
        need at least \(String(format: "%.1f", Double(minimumSamples) / fs)) s \
        (timing marker + \(Int(sweepDuration)) s sweep + 3 s of room decay).
        Start recording BEFORE playing the stimulus and keep recording at least
        5 seconds after the sweep ends.
        """)
    }

    // --- Marker detection -----------------------------------------------------
    let spacing = TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: sweep.samples.count)
    guard let detection = TimingReference.detect(
        marker: marker, in: recording, expectedMarkerSpacing: spacing
    ) else {
        fail("Recording is shorter than the timing marker — this file does not contain a measurement.")
    }
    print(String(format: "Marker confidence: %.1f dB (minimum %.0f dB)",
                 detection.confidenceDB, TimingReference.minimumConfidenceDB))
    if detection.confidenceDB < TimingReference.minimumConfidenceDB {
        fail("""
        Timing marker not found with enough confidence (\(String(format: "%.1f", detection.confidenceDB)) dB, need ≥ \(Int(TimingReference.minimumConfidenceDB)) dB).
        Likely causes: playback volume too low, heavy background noise, or the
        wrong file was played. Play the stimulus louder (clearly audible chirp
        at the start) and record again.
        """)
    }
    print(String(format: "Marker found %.3f s into the recording (detected playback latency/offset)",
                 Double(detection.markerStartIndex) / fs))
    if let drift = detection.clockDriftPPM {
        print(String(format: "Clock drift (playback vs capture): %+.0f ppm", drift))
    }

    // --- SNR estimate ---------------------------------------------------------
    let ambientEnd = max(0, detection.markerStartIndex - Int(0.05 * fs))
    if ambientEnd > Int(0.3 * fs) {
        let ambient = Array(recording[..<ambientEnd])
        let sweepStart = min(detection.stimulusStartIndex, recording.count - 1)
        let sweepEnd = min(sweepStart + sweep.samples.count, recording.count)
        let sweepRegion = Array(recording[sweepStart..<sweepEnd])
        if let snr = NoiseFloor.signalToNoiseDB(signal: sweepRegion, ambient: ambient) {
            print(String(format: "SNR estimate (sweep vs pre-marker ambient): %.1f dB", snr))
            if snr < 40 {
                print("WARNING: SNR below 40 dB — T30 in quiet bands may be unreliable. Consider a louder sweep or a quieter room.")
            }
        }
    } else {
        print("SNR estimate: skipped (less than 0.3 s of ambient before the marker — start recording earlier next time)")
    }

    // --- Deconvolution + analysis ----------------------------------------------
    let aligned = Array(recording[min(detection.stimulusStartIndex, recording.count - 1)...])
    let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
    let ir = ImpulseResponse(
        samples: deconvolved.impulseResponse,
        sampleRate: deconvolved.sampleRate,
        directIndex: deconvolved.peakIndex
    )
    let decays = ReverbTime.analyze(ir)

    print("")
    printDecayTable(decays)
    if let mid = ReverbTime.midBandRT60(decays) {
        print(String(format: "\nMid-band RT60: %.3f s", mid))
    }
    if let ratio = ReverbTime.lowToMidDecayRatio(decays) {
        print(String(format: "LF/mid decay ratio: %.2f", ratio))
    }
    if let c80 = Clarity.c80(ir) {
        print(String(format: "C80: %+.1f dB", c80))
    }
    print("(All figures are estimates from a consumer microphone, not lab measurements.)")

    if let rewPath = flagValue("--rew", in: args) {
        runREWComparison(decays: decays, rewPath: rewPath, criteriaBands: 250...4_000)
    }

case "rt60":
    guard args.count >= 2 else { fail("rt60: missing <ir> argument") }
    let url = URL(fileURLWithPath: args[1])
    let audio: WAVFile.Audio
    do {
        audio = try AudioLoader.load(url: url)
    } catch {
        fail("Could not read \(url.path): \(error)")
    }
    let ir = ImpulseResponse(samples: audio.samples, sampleRate: audio.sampleRate)
    let decays = ReverbTime.analyze(ir)

    print("Impulse response: \(audio.samples.count) samples @ \(Int(audio.sampleRate)) Hz")
    print("")
    printDecayTable(decays)
    if let mid = ReverbTime.midBandRT60(decays) {
        print(String(format: "\nMid-band RT60: %.3f s", mid))
    }
    if let ratio = ReverbTime.lowToMidDecayRatio(decays) {
        print(String(format: "LF/mid decay ratio: %.2f", ratio))
    }
    if let c80 = Clarity.c80(ir) {
        print(String(format: "C80: %+.1f dB", c80))
    }

    if let rewPath = flagValue("--rew", in: args) {
        runREWComparison(decays: decays, rewPath: rewPath, criteriaBands: ComparisonHarness.criteriaBands)
    }

case "stimulus":
    guard args.count >= 2 else { fail("stimulus: missing <output.wav> argument") }
    let duration = flagValue("--duration", in: args).flatMap(Double.init) ?? 10
    let rate = flagValue("--rate", in: args).flatMap(Double.init) ?? 48_000
    let bits = flagValue("--bits", in: args).flatMap(Int.init) ?? 24
    let tail = flagValue("--tail", in: args).flatMap(Double.init) ?? 5
    let peakDBFS = flagValue("--peak-dbfs", in: args).flatMap(Double.init) ?? -6
    let includeEndMarker = hasFlag("--end-marker", in: args)

    let sweep = SineSweep(parameters: .init(duration: duration, sampleRate: rate))
    let marker = TimingReference.makeMarker(sampleRate: rate)
    let stimulus = TimingReference.assembleStimulus(
        marker: marker, payload: sweep.samples, includeEndMarker: includeEndMarker
    )
    let gain = pow(10.0, peakDBFS / 20)
    let samples = stimulus.map { $0 * gain } + [Double](repeating: 0, count: Int(tail * rate))

    let url = URL(fileURLWithPath: args[1])
    do {
        switch bits {
        case 16: try WAVFile.writePCM16Mono(samples: samples, sampleRate: rate, to: url)
        case 24: try WAVFile.writePCM24Mono(samples: samples, sampleRate: rate, to: url)
        case 32: try WAVFile.writeFloat32Mono(samples: samples, sampleRate: rate, to: url)
        default: fail("Unsupported --bits \(bits); use 16, 24, or 32")
        }
        print("Wrote stimulus: \(url.path)")
        print(String(
            format: "  %d-bit%@ mono @ %.0f Hz, peak %.1f dBFS, total %.2f s",
            bits, bits == 32 ? " float" : " PCM", rate, peakDBFS, Double(samples.count) / rate
        ))
        print(String(
            format: "  layout: marker %.0f ms + guard %.0f ms + ESS sweep %.0f s%@ + %.0f s silence",
            Double(marker.samples.count) / rate * 1_000, marker.guardInterval * 1_000,
            duration, includeEndMarker ? " + guard + end marker" : "", tail
        ))
    } catch {
        fail("Could not write \(url.path): \(error)")
    }

case "edc":
    guard args.count >= 2 else { fail("edc: missing <recording> argument") }
    guard let band = flagValue("--band", in: args).flatMap(Double.init) else {
        fail("edc: missing --band <Hz>")
    }
    let url = URL(fileURLWithPath: args[1])
    let sweepDuration = flagValue("--duration", in: args).flatMap(Double.init) ?? 10
    let audio: WAVFile.Audio
    do {
        audio = try AudioLoader.load(url: url)
    } catch {
        fail("Could not read \(url.path): \(error)")
    }
    let fs = audio.sampleRate
    let sweep = SineSweep(parameters: .init(
        startFrequency: 20, endFrequency: 20_000, duration: sweepDuration, sampleRate: fs
    ))
    let marker = TimingReference.makeMarker(sampleRate: fs)
    guard let detection = TimingReference.detect(marker: marker, in: audio.samples),
          detection.confidenceDB >= TimingReference.minimumConfidenceDB
    else { fail("Timing marker not found — is this a measurement recording?") }
    let aligned = Array(audio.samples[min(detection.stimulusStartIndex, audio.samples.count - 1)...])
    let deconvolved = Deconvolution.impulseResponse(from: aligned, sweep: sweep)
    let ir = ImpulseResponse(
        samples: deconvolved.impulseResponse,
        sampleRate: deconvolved.sampleRate,
        directIndex: deconvolved.peakIndex
    )

    let filtered = OctaveBand.filtered(ir.samples, center: band, sampleRate: ir.sampleRate)
    print("EDC diagnostics: \(Int(band)) Hz octave band of \(url.lastPathComponent)")
    print("margin = dB above the estimated noise floor at which backward integration truncates")
    print("(margin -999 disables truncation: the full noisy tail is integrated)")
    print("")
    print("Margin (dB) | Noise floor | Truncation |   EDT   |   T20 (r²)      |   T30 (r²)")
    print("------------|-------------|------------|---------|-----------------|----------------")
    func fmt(_ f: (rt60: Double, rSquared: Double)?) -> String {
        f.map { String(format: "%.3f s (%.3f)", $0.rt60, $0.rSquared) } ?? "   —           "
    }
    for margin in [4.0, 8.0, 12.0, -999.0] {
        let curve = SchroederIntegration.decayCurve(
            of: filtered, sampleRate: ir.sampleRate, noiseMarginDB: margin
        )
        let t20 = ReverbTime.fit(curve: curve, from: -5, to: -25)
        let t30 = ReverbTime.fit(curve: curve, from: -5, to: -35)
        let edt = ReverbTime.fit(curve: curve, from: -0.1, to: -10)
        let label = margin <= -100 ? "  disabled " : String(format: "%10.0f ", margin)
        print(String(
            format: "%@| %8.1f dB | %7.3f s  | %@ | %@ | %@",
            label, curve.noiseFloorDB,
            Double(curve.truncationIndex) / ir.sampleRate,
            edt.map { String(format: "%.3f s", $0.rt60) } ?? "   —   ",
            fmt(t20), fmt(t30)
        ))
    }

    // Fit-window sensitivity at the default margin: where the two fit points
    // sit on a bent (cliff- or noise-contaminated) EDC changes the answer;
    // this table shows by how much.
    let curve = SchroederIntegration.decayCurve(of: filtered, sampleRate: ir.sampleRate)
    print("")
    print("Fit-window sensitivity (margin 8 dB):")
    print("  Window        | RT60 (r²)")
    print("  --------------|----------------")
    for (upper, lower) in [(-5.0, -25.0), (-5.0, -35.0), (-10.0, -30.0), (-10.0, -40.0), (-15.0, -45.0), (-20.0, -50.0)] {
        let f = ReverbTime.fit(curve: curve, from: upper, to: lower)
        print(String(format: "  %4.0f…%4.0f dB | %@", upper, lower, fmt(f)))
    }

default:
    fail("Unknown command: \(command). Use `measure`, `rt60`, `stimulus`, or `edc`.")
}
