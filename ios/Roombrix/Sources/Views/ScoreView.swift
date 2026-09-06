import SwiftUI
import SwiftData
import RoombrixScoring

/// Milestone 2: Room Score presentation. Scores from the built-in mic are
/// ALWAYS shown as a range — never a false-precision single integer — and
/// the provisional-calibration status is always visible.
struct ScoreView: View {
    @Query(sort: \MeasurementRecord.date, order: .reverse)
    private var records: [MeasurementRecord]

    var body: some View {
        NavigationStack {
            if let latest = records.first {
                List {
                    scoreCard(latest)
                    if let baseline = records.first(where: { $0.isBaseline }),
                       baseline.persistentModelID != latest.persistentModelID {
                        Section("Before / After") {
                            NavigationLink {
                                BeforeAfterView(baseline: baseline, current: latest)
                            } label: {
                                HStack {
                                    Label("Compare with baseline", systemImage: "arrow.left.arrow.right")
                                    Spacer()
                                    Text("\(Int((latest.scoreValue - baseline.scoreValue).rounded()) >= 0 ? "+" : "")\(Int((latest.scoreValue - baseline.scoreValue).rounded()))")
                                        .monospacedDigit()
                                        .foregroundStyle(latest.scoreValue >= baseline.scoreValue ? .green : .red)
                                }
                            }
                        }
                    }
                    if let problem = latest.topProblemText {
                        Section("Top problem") {
                            Text(problem)
                        }
                    }
                    if let score = latest.decodedScore {
                        Section("Subscores") {
                            ForEach(score.subscores, id: \.kind) { subscore in
                                SubscoreRow(subscore: subscore)
                            }
                        }
                    }
                    Section("Share") {
                        ShareCardSection(card: ScoreCardView(record: latest), label: "Share score card")
                    }
                    Section {
                        Label(ScoreEngine.calibrationNote, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if records.count > 1 {
                        Section("History") {
                            ForEach(records.dropFirst()) { record in
                                NavigationLink {
                                    RecordDetailView(record: record)
                                } label: {
                                    HStack {
                                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                        Spacer()
                                        Text(rangeText(record))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Room Score")
            } else {
                ContentUnavailableView(
                    "No measurements yet",
                    systemImage: "gauge.with.needle",
                    description: Text("Run a measurement on the Measure tab to see your Room Score.")
                )
                .navigationTitle("Room Score")
            }
        }
    }

    private func scoreCard(_ record: MeasurementRecord) -> some View {
        Section {
            VStack(spacing: 8) {
                Text(rangeText(record))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("out of 100 — built-in mic, shown as a range")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func rangeText(_ record: MeasurementRecord) -> String {
        "\(Int(record.scoreLow.rounded()))–\(Int(record.scoreHigh.rounded()))"
    }
}

struct SubscoreRow: View {
    let subscore: Subscore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(subscore.kind.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(subscore.isMeasured ? "\(Int(subscore.value.rounded()))" : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Gauge(value: subscore.value, in: 0...100) { EmptyView() }
                .tint(gaugeColor)
            Text(subscore.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var gaugeColor: Color {
        switch subscore.value {
        case ..<40: return .red
        case ..<70: return .orange
        default: return .green
        }
    }
}

struct RecordDetailView: View {
    let record: MeasurementRecord
    @Query private var allRecords: [MeasurementRecord]

    var body: some View {
        List {
            Section {
                if record.isBaseline {
                    Label("This is the baseline ('before') measurement", systemImage: "flag.fill")
                        .foregroundStyle(.blue)
                    Button("Remove baseline mark") { record.isBaseline = false }
                } else {
                    Button {
                        for other in allRecords { other.isBaseline = false }
                        record.isBaseline = true
                    } label: {
                        Label("Use as baseline ('before' state)", systemImage: "flag")
                    }
                }
            } footer: {
                Text("Mark the measurement taken BEFORE a change (treatment installed, speakers moved). New measurements are then compared against it on the Score tab.")
            }
            Section("Room Score") {
                LabeledContent(
                    "Score",
                    value: "\(Int(record.scoreLow.rounded()))–\(Int(record.scoreHigh.rounded()))"
                )
                LabeledContent("Engine version", value: record.scoreEngineVersion)
            }
            if let score = record.decodedScore {
                Section("Subscores") {
                    ForEach(score.subscores, id: \.kind) { subscore in
                        SubscoreRow(subscore: subscore)
                    }
                }
            }
            Section("Full report") {
                Text(record.reportText)
                    .font(.footnote.monospaced())
                ShareLink(item: record.reportText) {
                    Label("Share report", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(record.date.formatted(date: .abbreviated, time: .shortened))
    }
}
