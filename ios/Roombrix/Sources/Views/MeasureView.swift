import SwiftUI
import RoombrixAcoustics

/// Milestone 1 measurement flow: guided capture → intake gates → metrics.
struct MeasureView: View {
    @StateObject private var coordinator = MeasurementCoordinator()
    @State private var deviceCheckText: String?
    @State private var runningDeviceCheck = false

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.phase {
                case .idle:
                    startScreen
                case .preparing:
                    ProgressView("Preparing audio…")
                case .capturingAmbient(let seconds):
                    phaseScreen(
                        icon: "ear",
                        title: "Listening to your room",
                        detail: "Keep quiet — measuring background noise. \(seconds) s"
                    )
                case .playing(let seconds):
                    phaseScreen(
                        icon: "speaker.wave.3",
                        title: "Measuring",
                        detail: "Chirp, sweep, then silence. Don't move or talk. \(seconds) s"
                    )
                case .waitingForExternalPlayback:
                    VStack(spacing: 16) {
                        phaseScreen(
                            icon: "play.circle",
                            title: "Play the test file now",
                            detail: "Start the Roombrix stimulus on your system. Tap Done a few seconds after it finishes."
                        )
                        Button("Done — playback finished") {
                            coordinator.finishListenOnly()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .processing:
                    ProgressView("Analyzing…")
                case .done:
                    if let result = coordinator.result {
                        ResultView(result: result, onRestart: { coordinator.cancel() })
                    }
                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(message)
                            .multilineTextAlignment(.center)
                        Button("Try again") { coordinator.cancel() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Measure")
        }
    }

    private var startScreen: some View {
        List {
            Section("Start a measurement") {
                Button {
                    Task { await coordinator.start(path: .inApp) }
                } label: {
                    Label("Play through this phone's route", systemImage: "airplayaudio")
                }
                Button {
                    Task { await coordinator.start(path: .listenOnly) }
                } label: {
                    Label("I'll play the test file from my system", systemImage: "externaldrive")
                }
            }
            Section("Before you start") {
                Text("Put the phone at your listening position at ear height, mic unobstructed. The sweep should be clearly loud, but never painful.")
                    .font(.footnote)
            }
            Section("Device check") {
                Button {
                    runningDeviceCheck = true
                    Task {
                        let engine = AudioMeasurementEngine()
                        _ = try? engine.configureSession()
                        let outcome = await DeviceCheck.run(engine: engine)
                        deviceCheckText = outcome?.reportText ?? "Device check failed to run."
                        runningDeviceCheck = false
                    }
                } label: {
                    if runningDeviceCheck {
                        ProgressView()
                    } else {
                        Label("Verify AGC is off (plays 3 tones)", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                if let deviceCheckText {
                    Text(deviceCheckText)
                        .font(.footnote.monospaced())
                    ShareLink(item: deviceCheckText) {
                        Label("Share device check result", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                Text("Roombrix reports estimates, not lab measurements. Results with the built-in mic carry wider uncertainty than with a calibrated mic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phaseScreen(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(title).font(.title2.bold())
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Band table + summary; exports the CLI-comparable text report and the raw
/// capture WAV for cross-verification.
struct ResultView: View {
    let result: MeasurementResult
    let onRestart: () -> Void

    var body: some View {
        List {
            Section("Decay per band") {
                ForEach(result.report.bandDecays, id: \.centerFrequency) { band in
                    HStack {
                        Text(bandLabel(band.centerFrequency))
                            .frame(width: 64, alignment: .leading)
                        switch band.selectedMetric {
                        case .unmeasurable:
                            Text("not measurable in this capture")
                                .foregroundStyle(.secondary)
                        default:
                            if let rt = ReverbTime.bestEstimate(band) {
                                Text(String(format: "%.2f s", rt))
                                Text(band.selectedMetric == .t20 ? "T20" : "T30")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("unreliable fit")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let range = band.usableDecayRangeDB {
                            Text(String(format: "%.0f dB", range))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Summary") {
                if let mid = result.report.midBandRT60 {
                    LabeledContent("Mid-band RT60", value: String(format: "%.2f s", mid))
                }
                if let ratio = result.report.lowToMidDecayRatio {
                    LabeledContent("Bass/mid decay ratio", value: String(format: "%.2f×", ratio))
                }
                if let c80 = result.report.c80 {
                    LabeledContent("Clarity C80", value: String(format: "%+.1f dB", c80))
                }
                LabeledContent("Marker confidence", value: String(format: "%.1f dB", result.markerConfidenceDB))
                if let snr = result.snrDB {
                    LabeledContent("SNR estimate", value: String(format: "%.1f dB", snr))
                }
            }
            Section("Export") {
                ShareLink(item: result.reportText) {
                    Label("Share text report", systemImage: "doc.text")
                }
                if let url = result.recordingURL {
                    ShareLink(item: url) {
                        Label("Share raw recording (WAV)", systemImage: "waveform")
                    }
                }
            }
            Section {
                Button("New measurement", action: onRestart)
            }
            Section {
                Text("Estimates from this device's microphone — not lab measurements.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bandLabel(_ f: Double) -> String {
        f >= 1_000 ? String(format: "%.0f kHz", f / 1_000) : String(format: "%.0f Hz", f)
    }
}

struct ScoreView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Room Score arrives in Milestone 2",
                systemImage: "gauge.with.needle",
                description: Text("Measurements already collect everything the score needs.")
            )
            .navigationTitle("Room Score")
        }
    }
}

struct PlanView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Treatment plan arrives in Milestone 3",
                systemImage: "square.grid.3x3.topleft.filled",
                description: Text("After scoring, Roombrix maps problems to physical treatment with placement.")
            )
            .navigationTitle("Plan")
        }
    }
}
