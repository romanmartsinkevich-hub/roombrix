import SwiftUI
#if canImport(RoomPlan)
import RoomPlan
import simd
#endif

/// Capability gate + thin wrapper for RoomPlan. HARD RULE: nothing outside
/// this file may depend on RoomPlan or LiDAR — manual entry is the primary
/// path and every geometry feature works without a scan.
enum RoomScanSupport {
    static var isAvailable: Bool {
        #if canImport(RoomPlan)
        return RoomCaptureSession.isSupported
        #else
        return false
        #endif
    }
}

/// Scan sheet: runs a RoomPlan capture and reduces the result to L×W×H for
/// the manual-entry form. On unsupported devices this view is never
/// reachable (the entry button is hidden), but it still degrades cleanly.
struct RoomScanSheet: View {
    let onDimensions: (Double, Double, Double) -> Void
    let onCancel: () -> Void

    var body: some View {
        #if canImport(RoomPlan)
        if RoomScanSupport.isAvailable {
            NavigationStack {
                RoomCaptureRepresentable(onDimensions: onDimensions)
                    .ignoresSafeArea()
                    .navigationTitle("Scan the room")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                    }
            }
        } else {
            unsupportedFallback
        }
        #else
        unsupportedFallback
        #endif
    }

    private var unsupportedFallback: some View {
        VStack(spacing: 12) {
            Text("Room scanning needs a LiDAR-equipped device.")
            Button("Enter dimensions manually", action: onCancel)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#if canImport(RoomPlan)
private struct RoomCaptureRepresentable: UIViewRepresentable {
    let onDimensions: (Double, Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDimensions: onDimensions)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = context.coordinator
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        uiView.captureSession.stop()
    }

    final class Coordinator: NSObject, RoomCaptureViewDelegate {
        let onDimensions: (Double, Double, Double) -> Void

        init(onDimensions: @escaping (Double, Double, Double) -> Void) {
            self.onDimensions = onDimensions
        }

        // RoomCaptureViewDelegate conforms to NSCoding; stubs are required.
        func encode(with coder: NSCoder) {}
        required init?(coder: NSCoder) { return nil }

        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
            true
        }

        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            guard error == nil, !processedResult.walls.isEmpty else { return }
            // Reduce the captured walls to a bounding L×W×H. The rectangular
            // reduction is deliberate: the whole engine works on L×W×H, and
            // the user can correct the numbers by hand afterwards.
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
            var maxHeight: Float = 0
            for wall in processedResult.walls {
                let position = wall.transform.columns.3
                minX = min(minX, position.x); maxX = max(maxX, position.x)
                minZ = min(minZ, position.z); maxZ = max(maxZ, position.z)
                maxHeight = max(maxHeight, wall.dimensions.y)
            }
            let sideA = Double(maxX - minX)
            let sideB = Double(maxZ - minZ)
            guard sideA > 1, sideB > 1, maxHeight > 1 else { return }
            // Length = the longer horizontal extent by convention.
            onDimensions(max(sideA, sideB), min(sideA, sideB), Double(maxHeight))
        }
    }
}
#endif
