import SwiftUI
import SwiftData
import RoombrixGeometry
import RoombrixScoring
import RoombrixDiagnosis

/// Milestone 3: geometry, first-reflection points, and the rule-based
/// treatment plan — all driven by manually entered L×W×H plus markers.
struct PlanView: View {
    @Query private var rooms: [RoomRecord]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var coordinator: MeasurementCoordinator
    @AppStorage("activeRoomName") private var activeRoomName = ""

    /// The room all tabs work with. Selection survives restarts by name.
    var activeRoom: RoomRecord? {
        rooms.first { $0.name == activeRoomName } ?? rooms.first
    }

    var body: some View {
        NavigationStack {
            if let room = activeRoom {
                planContent(room: room)
                    .navigationTitle(room.name)
                    .toolbar {
                        Menu {
                            ForEach(rooms, id: \.persistentModelID) { candidate in
                                Button(candidate.name + (candidate.persistentModelID == room.persistentModelID ? " ✓" : "")) {
                                    activeRoomName = candidate.name
                                }
                            }
                            Divider()
                            Button("New room…") {
                                let newRoom = RoomRecord(name: "Room \(rooms.count + 1)")
                                modelContext.insert(newRoom)
                                activeRoomName = newRoom.name
                            }
                        } label: {
                            Label("Rooms", systemImage: "square.split.bottomrightquarter")
                        }
                        NavigationLink("Edit") {
                            RoomSetupView(room: room)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("Set up your room", systemImage: "square.grid.3x3.topleft.filled")
                } description: {
                    Text("Enter your room's dimensions and mark the speakers and your seat — no scanning required.")
                } actions: {
                    Button("Set up room") {
                        modelContext.insert(RoomRecord())
                    }
                    .buttonStyle(.borderedProminent)
                }
                .navigationTitle("Plan")
            }
        }
    }

    @ViewBuilder
    private func planContent(room: RoomRecord) -> some View {
        let diagnosis: Diagnosis? = coordinator.result.map { result in
            DiagnosisEngine.diagnose(.init(
                report: result.report,
                geometry: room.geometry,
                purpose: .listening,
                speakerPositions: room.speakerPositions,
                listenerPosition: room.listenerPosition
            ))
        }

        List {
            Section("Floor plan") {
                FloorPlanCanvas(
                    room: room,
                    recommendations: diagnosis?.recommendations ?? []
                )
                .frame(minHeight: 280)
                Text("Purple dots: first-reflection points (dashed = ceiling bounce). Orange walls: treatment placement from your plan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let diagnosis {
                if diagnosis.problems.isEmpty {
                    Section {
                        Label("No significant problems diagnosed in the latest measurement.", systemImage: "checkmark.circle")
                    }
                } else {
                    Section("Problems (latest measurement)") {
                        ForEach(Array(diagnosis.problems.enumerated()), id: \.offset) { _, problem in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(problem.title).font(.subheadline.weight(.semibold))
                                Text(problem.explanation).font(.footnote)
                            }
                        }
                    }
                    Section("Treatment plan") {
                        ForEach(Array(diagnosis.recommendations.enumerated()), id: \.offset) { index, rec in
                            RecommendationRow(index: index + 1, recommendation: rec)
                        }
                    }
                }
            } else {
                Section {
                    Label("Run a measurement to turn this floor plan into a treatment plan.", systemImage: "waveform")
                        .font(.footnote)
                }
            }

            Section("Predicted room modes (rectangular approximation)") {
                if room.geometry.modalPredictionIsReliable {
                    ModePredictionView(geometry: room.geometry)
                } else {
                    Text("This room is too irregular for reliable modal prediction — measured low-frequency data is used instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RecommendationRow: View {
    let index: Int
    let recommendation: Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index).").font(.headline)
                Text(recommendation.treatment?.displayName ?? "No purchase needed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(costLabel)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(.systemGray5)))
            }
            if let area = recommendation.areaSquareMeters {
                Text(String(format: "≈ %.1f m² of coverage", area))
                    .font(.footnote)
            }
            Text(recommendation.placement.description)
                .font(.footnote)
            Text(recommendation.rationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(String(
                format: "Predicted Room Score impact: +%.0f to +%.0f points (provisional calibration)",
                recommendation.predictedScoreImpact.lowerBound,
                recommendation.predictedScoreImpact.upperBound
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var costLabel: String {
        switch recommendation.costTier {
        case .free: return "free"
        case .low: return "€"
        case .medium: return "€€"
        case .high: return "€€€"
        }
    }
}

struct ModePredictionView: View {
    let geometry: RoomGeometry

    var body: some View {
        let modes = RoomModes.predict(for: geometry, maxFrequency: 120)
            .filter { $0.type == .axial }
            .prefix(8)
        ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
            HStack {
                Text(String(format: "%.1f Hz", mode.frequency))
                    .monospacedDigit()
                Spacer()
                Text("axial, along \(mode.drivingAxes.joined(separator: "/"))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Text("Axial modes below 120 Hz — where bass peaks and nulls live. Cross-checked against measured peaks during diagnosis.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
