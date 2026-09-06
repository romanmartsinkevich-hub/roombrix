import SwiftUI
import RoombrixGeometry

/// Room setup — manual dimensions are the PRIMARY, fully supported path.
/// A RoomPlan scan (LiDAR devices only) merely pre-fills the same fields
/// and is hidden entirely on unsupported hardware: no dead ends.
struct RoomSetupView: View {
    @Bindable var room: RoomRecord
    @State private var showingScanner = false

    var body: some View {
        Form {
            Section("Room dimensions (meters)") {
                dimensionRow("Length (front → back)", value: $room.length, range: 1.5...30)
                dimensionRow("Width (left → right)", value: $room.width, range: 1.5...30)
                dimensionRow("Height", value: $room.height, range: 1.8...8)
            }

            if RoomScanSupport.isAvailable {
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan with camera instead (LiDAR)", systemImage: "camera.metering.matrix")
                    }
                } footer: {
                    Text("Optional: a quick scan fills in the dimensions above. You can always correct them by hand.")
                }
            }

            Section("Speakers and listening position") {
                Text("Drag the markers to match your setup. The front wall (behind the speakers) is at the top.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                FloorPlanCanvas(room: room) { kind, point in
                    switch kind {
                    case .leftSpeaker:
                        room.leftSpeakerX = point.x
                        room.leftSpeakerY = point.y
                    case .rightSpeaker:
                        room.rightSpeakerX = point.x
                        room.rightSpeakerY = point.y
                    case .listener:
                        room.listenerX = point.x
                        room.listenerY = point.y
                    }
                    room.clampMarkers()
                }
                .frame(minHeight: 260)
                dimensionRow("Tweeter height", value: $room.speakerHeight, range: 0.2...2.5)
                dimensionRow("Ear height (seated)", value: $room.earHeight, range: 0.5...2.0)
            }

            Section {
                Text("Modal predictions assume a roughly rectangular room. For L-shaped or heavily irregular rooms, treat the mode list as indicative — measured low-frequency data always wins.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Room setup")
        .onChange(of: room.length) { _, _ in room.clampMarkers() }
        .onChange(of: room.width) { _, _ in room.clampMarkers() }
        .onChange(of: room.height) { _, _ in room.clampMarkers() }
        .sheet(isPresented: $showingScanner) {
            RoomScanSheet { length, width, height in
                room.length = length
                room.width = width
                room.height = height
                room.clampMarkers()
                showingScanner = false
            } onCancel: {
                showingScanner = false
            }
        }
    }

    private func dimensionRow(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Stepper("", value: value, in: range, step: 0.05)
                .labelsHidden()
        }
    }
}
