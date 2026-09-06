import SwiftUI
import SwiftData

@main
struct RoombrixApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [MeasurementRecord.self, RoomRecord.self])
    }
}

struct RootView: View {
    @StateObject private var coordinator = MeasurementCoordinator()

    var body: some View {
        TabView {
            MeasureView()
                .tabItem { Label("Measure", systemImage: "waveform") }
            ScoreView()
                .tabItem { Label("Score", systemImage: "gauge.with.needle") }
            PlanView()
                .tabItem { Label("Plan", systemImage: "square.grid.3x3.topleft.filled") }
        }
        .environmentObject(coordinator)
    }
}
