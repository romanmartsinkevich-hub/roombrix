import Foundation
import RoombrixAcoustics
import RoombrixDSP
import RoombrixValidation

// roombrix-validate — CLI validation harness.
//
// Usage:
//   roombrix-validate rt60 <ir.wav> [--rew <rew-rt60-export.txt>]
//       Analyze a WAV impulse response; optionally diff against a REW RT60
//       text export and report the acceptance verdict.
//
//   roombrix-validate stimulus <output.wav> [--duration 10] [--rate 48000]
//       Export the measurement stimulus (timing marker + guard + ESS sweep)
//       as a WAV file for playback from a streamer/USB stick.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func flagValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("""
    Usage:
      roombrix-validate rt60 <ir.wav> [--rew <rt60-export.txt>]
      roombrix-validate stimulus <output.wav> [--duration 10] [--rate 48000]
    """)
}

switch command {
case "rt60":
    guard args.count >= 2 else { fail("rt60: missing <ir.wav> argument") }
    let url = URL(fileURLWithPath: args[1])
    let audio: WAVFile.Audio
    do {
        audio = try WAVFile.read(url: url)
    } catch {
        fail("Could not read \(url.path): \(error)")
    }
    let ir = ImpulseResponse(samples: audio.samples, sampleRate: audio.sampleRate)
    let decays = ReverbTime.analyze(ir)

    print("Impulse response: \(audio.samples.count) samples @ \(Int(audio.sampleRate)) Hz")
    print("")
    print("Band (Hz) |   EDT   |   T20   |   T30   |  fit r²")
    print("----------|---------|---------|---------|--------")
    for d in decays {
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f s", $0) } ?? "   —   " }
        let quality = d.t20FitQuality.map { String(format: "%.3f", $0) } ?? "  —  "
        print(String(format: "%9.0f | %@ | %@ | %@ | %@",
                     d.centerFrequency, fmt(d.edt), fmt(d.t20), fmt(d.t30), quality))
    }
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
        let text: String
        do {
            text = try String(contentsOfFile: rewPath, encoding: .utf8)
        } catch {
            fail("Could not read REW export \(rewPath): \(error)")
        }
        do {
            let reference = try REWImport.parseRT60(text: text)
            let report = ComparisonHarness.compareRT60(roombrix: decays, reference: reference)
            print("\n=== REW comparison ===")
            print(report.summary)
            exit(report.passed ? 0 : 2)
        } catch {
            fail("Could not parse REW RT60 export: \(error)")
        }
    }

case "stimulus":
    guard args.count >= 2 else { fail("stimulus: missing <output.wav> argument") }
    let duration = flagValue("--duration", in: args).flatMap(Double.init) ?? 10
    let rate = flagValue("--rate", in: args).flatMap(Double.init) ?? 48_000
    let sweep = SineSweep(parameters: .init(duration: duration, sampleRate: rate))
    let marker = TimingReference.makeMarker(sampleRate: rate)
    let stimulus = TimingReference.assembleStimulus(
        marker: marker, payload: sweep.samples, includeEndMarker: true
    )
    let url = URL(fileURLWithPath: args[1])
    do {
        try WAVFile.writeFloat32Mono(samples: stimulus.map { $0 * 0.9 }, sampleRate: rate, to: url)
        print("Wrote stimulus: \(url.path)")
        print(String(format: "  marker %.0f ms + guard %.0f ms + ESS sweep %.0f s + guard + end marker @ %.0f Hz",
                     Double(marker.samples.count) / rate * 1_000,
                     marker.guardInterval * 1_000, duration, rate))
        print("  end marker enables clock-drift estimation (marker spacing: \(TimingReference.expectedMarkerSpacing(marker: marker, payloadCount: sweep.samples.count)) samples)")
    } catch {
        fail("Could not write \(url.path): \(error)")
    }

default:
    fail("Unknown command: \(command). Use `rt60` or `stimulus`.")
}
