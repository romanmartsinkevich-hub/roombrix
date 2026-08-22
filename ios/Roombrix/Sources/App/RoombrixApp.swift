import SwiftUI

@main
struct RoombrixApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            MeasureView()
                .tabItem { Label("Measure", systemImage: "waveform") }
            ScoreView()
                .tabItem { Label("Score", systemImage: "gauge.with.needle") }
            PlanView()
                .tabItem { Label("Plan", systemImage: "square.grid.3x3.topleft.filled") }
        }
    }
}
