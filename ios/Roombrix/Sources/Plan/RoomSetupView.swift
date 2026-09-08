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
            Section("Room name") {
                TextField("e.g. Living room, Studio, Garage", text: $room.name)
            }
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
                Text("Drag markers for a rough layout; the CENTIMETRE fields below are authoritative — measure with a tape and type the numbers. The front wall (behind the speakers) is at the top.")
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
            }

            Section("Left speaker (cm)") {
                cmRow("From front wall", meters: $room.leftSpeakerX)
                cmRow("From left wall", meters: $room.leftSpeakerY)
            }
            Section("Right speaker (cm)") {
                cmRow("From front wall", meters: $room.rightSpeakerX)
                cmRow("From left wall", meters: $room.rightSpeakerY)
            }
            Section("Listening position (cm)") {
                cmRow("From front wall", meters: $room.listenerX)
                cmRow("From left wall", meters: $room.listenerY)
            }
            Section("Heights (meters)") {
                dimensionRow("Tweeter height", value: $room.speakerHeight, range: 0.2...2.5)
                dimensionRow("Ear height (seated)", value: $room.earHeight, range: 0.5...2.0)
            }

            Section("Derived distances") {
                derivedRow("Speaker ↔ speaker", distance2D(
                    room.leftSpeakerX, room.leftSpeakerY,
                    room.rightSpeakerX, room.rightSpeakerY
                ))
                derivedRow("Seat → left speaker", distance2D(
                    room.listenerX, room.listenerY,
                    room.leftSpeakerX, room.leftSpeakerY
                ))
                derivedRow("Seat → right speaker", distance2D(
                    room.listenerX, room.listenerY,
                    room.rightSpeakerX, room.rightSpeakerY
                ))
                derivedRow("Left speaker → side wall", min(room.leftSpeakerY, room.width - room.leftSpeakerY))
                derivedRow("Right speaker → side wall", min(room.rightSpeakerY, room.width - room.rightSpeakerY))
                derivedRow("Seat → back wall", room.length - room.listenerX)
                Text("Symmetric side-wall distances and equal seat-to-speaker distances keep the stereo image centered. Placement recommendations (M5) build on these numbers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    /// Authoritative centimetre entry for a marker coordinate stored in
    /// meters. Clamped inside the room on commit.
    private func cmRow(_ label: String, meters: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(
                "",
                value: Binding(
                    get: { (meters.wrappedValue * 100).rounded() },
                    set: { newValue in
                        meters.wrappedValue = newValue / 100
                        room.clampMarkers()
                    }
                ),
                format: .number.precision(.fractionLength(0))
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            Text("cm").foregroundStyle(.secondary)
        }
    }

    private func derivedRow(_ label: String, _ meters: Double) -> some View {
        LabeledContent(label, value: String(format: "%.0f cm", meters * 100))
            .font(.subheadline)
    }

    private func distance2D(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        ((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)).squareRoot()
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
