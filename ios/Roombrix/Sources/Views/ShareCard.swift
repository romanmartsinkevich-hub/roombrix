import SwiftUI
import RoombrixScoring

/// Shareable score card — the organic-growth artifact from the brief.
/// Honesty rules apply on the card itself: score as a range, "estimate"
/// framing, provisional-calibration note.
struct ScoreCardView: View {
    let record: MeasurementRecord

    var body: some View {
        VStack(spacing: 14) {
            Text("ROOMBRIX")
                .font(.caption.weight(.black))
                .kerning(3)
                .foregroundStyle(.secondary)
            Text("Room Score")
                .font(.headline)
            Text("\(Int(record.scoreLow.rounded()))–\(Int(record.scoreHigh.rounded()))")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("out of 100")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let score = record.decodedScore {
                VStack(spacing: 6) {
                    ForEach(score.subscores, id: \.kind) { subscore in
                        HStack {
                            Text(subscore.kind.displayName)
                                .font(.caption)
                                .frame(width: 130, alignment: .leading)
                            if subscore.isMeasured {
                                Gauge(value: subscore.value, in: 0...100) { EmptyView() }
                                    .tint(subscore.value >= 70 ? .green : subscore.value >= 40 ? .orange : .red)
                            } else {
                                Text("not measured")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(subscore.isMeasured ? "\(Int(subscore.value.rounded()))" : "—")
                                .font(.caption.monospacedDigit())
                                .frame(width: 26, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 4)
            }

            Text(record.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Acoustic estimate, built-in mic · provisional calibration")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.quaternary))
    }
}

/// Before/after delta card.
struct DeltaCardView: View {
    let before: MeasurementRecord
    let after: MeasurementRecord

    private var delta: Int {
        Int((after.scoreValue - before.scoreValue).rounded())
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("ROOMBRIX")
                .font(.caption.weight(.black))
                .kerning(3)
                .foregroundStyle(.secondary)
            Text("Room Score — before → after")
                .font(.headline)
            HStack(spacing: 12) {
                Text("\(Int(before.scoreLow.rounded()))–\(Int(before.scoreHigh.rounded()))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                Text("\(Int(after.scoreLow.rounded()))–\(Int(after.scoreHigh.rounded()))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
            }
            .monospacedDigit()
            Text(delta >= 0 ? "+\(delta) points" : "\(delta) points")
                .font(.title3.weight(.bold))
                .foregroundStyle(delta >= 0 ? .green : .red)
            Text("\(before.date.formatted(date: .abbreviated, time: .omitted)) → \(after.date.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Acoustic estimates, built-in mic · provisional calibration")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.quaternary))
    }
}

/// Renders a card view to a shareable image (3× scale for crisp sharing).
@MainActor
enum CardRenderer {
    static func image<Card: View>(of card: Card) -> Image? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else { return nil }
        return Image(uiImage: uiImage)
    }
}
