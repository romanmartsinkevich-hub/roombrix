import SwiftUI
import RoombrixScoring

/// Milestone 4: before/after comparison — the loop-closing view.
/// Compares the marked baseline against the most recent measurement:
/// score delta, per-subscore deltas, per-band RT60 deltas, share card.
struct BeforeAfterView: View {
    let baseline: MeasurementRecord
    let current: MeasurementRecord

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        VStack {
                            Text("Before").font(.caption).foregroundStyle(.secondary)
                            Text(range(baseline))
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right")
                        VStack {
                            Text("After").font(.caption).foregroundStyle(.secondary)
                            Text(range(current))
                                .font(.title.weight(.bold))
                        }
                    }
                    .monospacedDigit()
                    Text(deltaText)
                        .font(.headline)
                        .foregroundStyle(scoreDelta >= 0 ? .green : .red)
                    Text("Same engine version required for a meaningful delta: \(baseline.scoreEngineVersion) → \(current.scoreEngineVersion)")
                        .font(.caption2)
                        .foregroundStyle(baseline.scoreEngineVersion == current.scoreEngineVersion
                            ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            if let beforeScore = baseline.decodedScore, let afterScore = current.decodedScore {
                Section("Subscore changes") {
                    ForEach(afterScore.subscores, id: \.kind) { after in
                        if let before = beforeScore.subscores.first(where: { $0.kind == after.kind }) {
                            HStack {
                                Text(after.kind.displayName).font(.subheadline)
                                Spacer()
                                Text("\(Int(before.value.rounded())) → \(Int(after.value.rounded()))")
                                    .monospacedDigit()
                                deltaBadge(after.value - before.value)
                            }
                        }
                    }
                }
            }

            Section("Decay per band (RT60)") {
                ForEach(bandRows) { row in
                    HStack {
                        Text(bandLabel(row.centerFrequency))
                            .frame(width: 60, alignment: .leading)
                        Text(row.beforeText).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2)
                        Text(row.afterText)
                        Spacer()
                        if let delta = row.deltaPercent {
                            Text(String(format: "%+.0f %%", delta))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(delta <= 0 ? .green : .orange)
                        }
                    }
                    .font(.subheadline)
                }
                Text("Green = decay got shorter (usually the goal of treatment). Bands may be unmeasurable in either capture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ShareCardSection(card: DeltaCardView(before: baseline, after: current), label: "Share before/after card")
            }
        }
        .navigationTitle("Before / After")
    }

    private var scoreDelta: Double { current.scoreValue - baseline.scoreValue }

    private var deltaText: String {
        let d = Int(scoreDelta.rounded())
        return d >= 0 ? "+\(d) points" : "\(d) points"
    }

    private func range(_ record: MeasurementRecord) -> String {
        "\(Int(record.scoreLow.rounded()))–\(Int(record.scoreHigh.rounded()))"
    }

    private func deltaBadge(_ delta: Double) -> some View {
        let d = Int(delta.rounded())
        return Text(d >= 0 ? "+\(d)" : "\(d)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(d >= 0 ? .green : .red)
            .frame(width: 36, alignment: .trailing)
    }

    private struct BandRow: Identifiable {
        var id: Double { centerFrequency }
        let centerFrequency: Double
        let beforeText: String
        let afterText: String
        let deltaPercent: Double?
    }

    private var bandRows: [BandRow] {
        let beforeBands = baseline.decodedBands
        let afterBands = current.decodedBands
        let centers = Set(beforeBands.map(\.centerFrequency))
            .union(afterBands.map(\.centerFrequency))
        return centers.sorted().map { center in
            let before = beforeBands.first { $0.centerFrequency == center }?.rt60
            let after = afterBands.first { $0.centerFrequency == center }?.rt60
            var delta: Double?
            if let before, let after, before > 0 {
                delta = (after - before) / before * 100
            }
            return BandRow(
                centerFrequency: center,
                beforeText: before.map { String(format: "%.2f s", $0) } ?? "—",
                afterText: after.map { String(format: "%.2f s", $0) } ?? "—",
                deltaPercent: delta
            )
        }
    }

    private func bandLabel(_ f: Double) -> String {
        f >= 1_000 ? String(format: "%.0f kHz", f / 1_000) : String(format: "%.0f Hz", f)
    }
}

/// Renders a card lazily and offers it via the share sheet.
struct ShareCardSection<Card: View>: View {
    let card: Card
    let label: String
    @State private var rendered: Image?

    var body: some View {
        VStack(spacing: 12) {
            card
                .frame(maxWidth: .infinity)
            if let rendered {
                ShareLink(
                    item: rendered,
                    preview: SharePreview("Roombrix Room Score", image: rendered)
                ) {
                    Label(label, systemImage: "square.and.arrow.up")
                }
            }
        }
        .task {
            rendered = CardRenderer.image(of: card)
        }
    }
}
