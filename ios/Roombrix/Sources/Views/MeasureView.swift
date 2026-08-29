import SwiftUI
import RoombrixAcoustics

/// Milestone 1 measurement flow — the phone is the instrument, never the
/// source: ambient → pink-noise level setting → sweep.
struct MeasureView: View {
    @StateObject private var coordinator = MeasurementCoordinator()
    @State private var packageURLs: (pink: URL, sweep: URL)?
    @State private var packageError: String?
    @State private var deviceCheckText: String?
    @State private var runningDeviceCheck = false

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.phase {
                case .idle:
                    startScreen
                case .preparing:
                    ProgressView("Preparing…")
                case .capturingAmbient(let seconds):
                    phaseScreen(
                        icon: "ear",
                        title: "Measuring background noise",
                        detail: "Stay quiet and still. \(seconds) s"
                    )
                case .ambientReview:
                    ambientReviewScreen
                case .levelSetting:
                    levelSettingScreen
                case .waitingForSweep:
                    sweepScreen(recordingStarted: false)
                case .recordingSweep:
                    sweepScreen(recordingStarted: true)
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
                        Text(message).multilineTextAlignment(.center)
                        Button("Start over") { coordinator.cancel() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Measure")
            .task { preparePackage() }
        }
    }

    private func preparePackage() {
        do {
            packageURLs = try StimulusPackage.ensureFiles()
        } catch {
            packageError = "Could not prepare the test files: \(error.localizedDescription)"
        }
    }

    // MARK: - Start

    private var startScreen: some View {
        List {
            Section("1 — Send the test files to your system") {
                if let urls = packageURLs {
                    ShareLink(item: urls.pink) {
                        Label("Pink noise (level setting, loop it)", systemImage: "waveform.path")
                    }
                    ShareLink(item: urls.sweep) {
                        Label("Measurement sweep", systemImage: "waveform")
                    }
                    Text("AirDrop them to your computer, save to Files, or copy to a USB stick — then play them from your own system (streamer, DAC, computer). The phone never plays the test sounds; it only listens. Both files are also in the Files app under Roombrix.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(packageError ?? "Preparing test files…")
                        .font(.footnote)
                }
            }
            Section("2 — Place the phone") {
                Text("Put the phone at your listening position at ear height — on a stand or resting screen-up on a cushion. Do NOT hold it: your body absorbs sound and any movement corrupts the measurement.")
                    .font(.footnote)
            }
            Section("3 — Measure") {
                Button {
                    Task { await coordinator.startAmbient() }
                } label: {
                    Label("Start measurement", systemImage: "record.circle")
                        .font(.headline)
                }
            }
            Section("Device check (once per device)") {
                Text("Loop the pink-noise file at a steady, comfortable volume first, then run this. It verifies the microphone's gain control is really off.")
                    .font(.footnote)
                Button {
                    runningDeviceCheck = true
                    Task {
                        let engine = AudioMeasurementEngine()
                        let outcome = await DeviceCheck.run(engine: engine)
                        deviceCheckText = outcome?.reportText ?? "Device check failed to run."
                        runningDeviceCheck = false
                    }
                } label: {
                    if runningDeviceCheck {
                        ProgressView()
                    } else {
                        Label("Run device check (records 8 s)", systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                if let deviceCheckText {
                    Text(deviceCheckText).font(.footnote.monospaced())
                    ShareLink(item: deviceCheckText) {
                        Label("Share device check result", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                Text("Roombrix reports estimates, not lab measurements.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Ambient review

    private var ambientReviewScreen: some View {
        List {
            Section("Background noise per band") {
                ForEach(coordinator.ambientBandLevels) { band in
                    LabeledContent(bandLabel(band.frequency),
                                   value: String(format: "%.0f dBFS", band.levelDB))
                }
            }
            if let warning = coordinator.ambientWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button {
                    coordinator.startLevelSetting()
                } label: {
                    Label("Continue — set the level with pink noise", systemImage: "arrow.right.circle")
                        .font(.headline)
                }
                Button("Redo background measurement") {
                    Task { await coordinator.startAmbient() }
                }
            } footer: {
                Text("Next: start the pink-noise file on your system, on loop. You'll see a live level readout here.")
            }
        }
    }

    // MARK: - Level setting

    private var levelSettingScreen: some View {
        List {
            Section {
                trafficLightView
            }
            Section("Headroom per band (target ≥ \(Int(MeasurementConstants.targetSNRdB)) dB)") {
                ForEach(coordinator.liveSNR) { band in
                    HStack {
                        Text(bandLabel(band.frequency)).frame(width: 64, alignment: .leading)
                        Gauge(value: min(max(band.snrDB, 0), 60), in: 0...60) { EmptyView() }
                            .tint(band.snrDB >= MeasurementConstants.targetSNRdB ? .green : .orange)
                        Text(String(format: "%.0f dB", band.snrDB))
                            .frame(width: 52, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
            }
            Section {
                Button {
                    coordinator.confirmLevel()
                } label: {
                    Label("Level is set — continue", systemImage: "checkmark.circle")
                        .font(.headline)
                }
            } footer: {
                Text("Play the pink-noise file on loop and raise the volume until everything is green (loud, but never painful). Then STOP the pink noise, keep the volume knob where it is, and continue.")
            }
        }
    }

    private var trafficLightView: some View {
        HStack(spacing: 12) {
            switch coordinator.trafficLight {
            case .tooQuiet:
                Image(systemName: "speaker.wave.1").foregroundStyle(.orange)
                Text("Too quiet — raise the volume")
            case .good:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Good level — stop the pink noise and continue")
            case .clipping:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("Clipping — turn it down")
            }
        }
        .font(.headline)
    }

    // MARK: - Sweep

    private func sweepScreen(recordingStarted: Bool) -> some View {
        VStack(spacing: 20) {
            phaseScreen(
                icon: recordingStarted ? "waveform" : "play.circle",
                title: recordingStarted ? "Recording the sweep" : "Play the sweep file now",
                detail: recordingStarted
                    ? "Hold still and stay quiet. Recording stops automatically after the sweep and the room's decay."
                    : "At the SAME volume you just set: play the measurement sweep from your system. Recording is already running — footsteps on the way are fine."
            )
            Button("Stop recording now") {
                coordinator.finishSweep()
            }
            .buttonStyle(.bordered)
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

    private func bandLabel(_ f: Double) -> String {
        f >= 1_000 ? String(format: "%.0f kHz", f / 1_000) : String(format: "%.0f Hz", f)
    }
}

/// Band table + summary; exports the CLI-comparable text report and the raw
/// capture WAV for cross-verification.
struct ResultView: View {
    let result: MeasurementResult
    let onRestart: () -> Void

    var body: some View {
        List {
            if let warning = result.levelChangeWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
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
                description: Text("Works from manually entered room dimensions — no LiDAR required.")
            )
            .navigationTitle("Plan")
        }
    }
}
