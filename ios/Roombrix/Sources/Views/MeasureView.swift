import SwiftUI

/// Measurement flow entry point (Milestone 1 UI shell).
struct MeasureView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Start a measurement") {
                    Label("Play test file from your system", systemImage: "externaldrive")
                    Label("Play through this phone (AirPlay/Bluetooth)", systemImage: "airplayaudio")
                }
                Section {
                    Text("Roombrix measures with an estimate-honest approach: results with the built-in microphone are shown as ranges, never lab-grade single numbers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Measure")
        }
    }
}

struct ScoreView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No measurements yet",
                systemImage: "gauge.with.needle",
                description: Text("Run a measurement to see your Room Score and what's behind it.")
            )
            .navigationTitle("Room Score")
        }
    }
}

struct PlanView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No plan yet",
                systemImage: "square.grid.3x3.topleft.filled",
                description: Text("After a measurement, your treatment plan and placement map appear here.")
            )
            .navigationTitle("Plan")
        }
    }
}
