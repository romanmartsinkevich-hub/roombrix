import SwiftUI
import RoombrixGeometry
import RoombrixDiagnosis

/// 2D floor plan: room outline to scale, speaker/listener markers,
/// first-reflection points from the image-source model, and treatment
/// surfaces highlighted from the recommendations. Pure 2D — works from
/// manually entered dimensions, no LiDAR anywhere.
struct FloorPlanCanvas: View {
    let room: RoomRecord
    var recommendations: [Recommendation] = []
    /// Marker dragging (used by the setup editor); nil = read-only plan.
    var onDragMarker: ((MarkerKind, Point3D) -> Void)?

    enum MarkerKind { case leftSpeaker, rightSpeaker, listener }

    private struct Layout {
        let scale: Double
        let origin: CGPoint

        func point(_ x: Double, _ y: Double) -> CGPoint {
            // Room x (length) maps to screen vertical, y (width) horizontal:
            // portrait rooms fit phone screens naturally.
            CGPoint(x: origin.x + y * scale, y: origin.y + x * scale)
        }

        func meters(_ p: CGPoint) -> (x: Double, y: Double) {
            ((Double(p.y) - Double(origin.y)) / scale, (Double(p.x) - Double(origin.x)) / scale)
        }
    }

    private func layout(in size: CGSize) -> Layout {
        let margin = 24.0
        let scale = min(
            (Double(size.width) - 2 * margin) / room.width,
            (Double(size.height) - 2 * margin) / room.length
        )
        let origin = CGPoint(
            x: (Double(size.width) - room.width * scale) / 2,
            y: (Double(size.height) - room.length * scale) / 2
        )
        return Layout(scale: scale, origin: origin)
    }

    private var treatedSurfaces: Set<Surface> {
        Set(recommendations.flatMap { $0.placement.surfaces })
    }

    private var reflections: [ImageSource.Reflection] {
        room.speakerPositions.flatMap { speaker in
            ImageSource.criticalReflections(
                speaker: speaker,
                listener: room.listenerPosition,
                room: room.geometry
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = layout(in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    draw(context: context, layout: layout)
                }
                markers(layout: layout)
            }
        }
        .aspectRatio(CGFloat(room.width / room.length), contentMode: .fit)
    }

    private func draw(context: GraphicsContext, layout: Layout) {
        // Room outline; front wall (speakers' end, x = 0) drawn at the top.
        let corner00 = layout.point(0, 0)
        let cornerLW = layout.point(room.length, room.width)
        let rect = CGRect(
            x: corner00.x, y: corner00.y,
            width: cornerLW.x - corner00.x, height: cornerLW.y - corner00.y
        )
        context.fill(Path(rect), with: .color(Color(.systemGray6)))

        // Walls, tinted when a recommendation targets them.
        func wallPath(_ surface: Surface) -> Path {
            var path = Path()
            switch surface {
            case .wallFront:
                path.move(to: layout.point(0, 0)); path.addLine(to: layout.point(0, room.width))
            case .wallBack:
                path.move(to: layout.point(room.length, 0)); path.addLine(to: layout.point(room.length, room.width))
            case .wallLeft:
                path.move(to: layout.point(0, 0)); path.addLine(to: layout.point(room.length, 0))
            case .wallRight:
                path.move(to: layout.point(0, room.width)); path.addLine(to: layout.point(room.length, room.width))
            default:
                break
            }
            return path
        }
        for surface in [Surface.wallFront, .wallBack, .wallLeft, .wallRight] {
            let treated = treatedSurfaces.contains(surface)
            context.stroke(
                wallPath(surface),
                with: .color(treated ? .orange : .primary),
                lineWidth: treated ? 5 : 2
            )
        }

        // First-reflection points: on-wall points as filled dots; the
        // ceiling bounce as a dashed ring at its floor projection.
        for reflection in reflections {
            let p = layout.point(reflection.point.x, reflection.point.y)
            let dot = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            switch reflection.surface {
            case .ceiling:
                context.stroke(
                    Path(ellipseIn: dot),
                    with: .color(.purple),
                    style: StrokeStyle(lineWidth: 2, dash: [3, 2])
                )
            case .floor:
                continue // floor bounce handled by rug advice, not drawn
            default:
                context.fill(Path(ellipseIn: dot), with: .color(.purple))
            }
        }
    }

    @ViewBuilder
    private func markers(layout: Layout) -> some View {
        marker("L", kind: .leftSpeaker,
               at: layout.point(room.leftSpeakerX, room.leftSpeakerY), layout: layout)
        marker("R", kind: .rightSpeaker,
               at: layout.point(room.rightSpeakerX, room.rightSpeakerY), layout: layout)
        marker("👂", kind: .listener,
               at: layout.point(room.listenerX, room.listenerY), layout: layout)
    }

    private func marker(_ label: String, kind: MarkerKind, at point: CGPoint, layout: Layout) -> some View {
        Text(label)
            .font(.caption.bold())
            .frame(width: 34, height: 34)
            .background(Circle().fill(kind == .listener ? Color.blue : Color.green).opacity(0.85))
            .foregroundStyle(.white)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard let onDragMarker else { return }
                        let meters = layout.meters(value.location)
                        let z = kind == .listener ? room.earHeight : room.speakerHeight
                        onDragMarker(kind, Point3D(x: meters.x, y: meters.y, z: z))
                    }
            )
            .allowsHitTesting(onDragMarker != nil)
    }
}
