import Foundation

/// First-order image-source model: where on each boundary the first
/// reflection between a speaker and the listener lands, its extra path
/// length, and arrival delay. These points are what the treatment plan
/// draws on the floor plan.
public enum ImageSource {

    public struct Reflection: Sendable {
        public let surface: Surface
        /// Reflection point on the surface, room coordinates.
        public let point: Point3D
        /// Total reflected path length, meters.
        public let pathLength: Double
        /// Delay relative to the direct sound, milliseconds.
        public let delayAfterDirectMs: Double
    }

    static let speedOfSound = 343.0

    /// Mirror a point across a boundary of the rectangular room.
    static func mirror(_ p: Point3D, across surface: Surface, in room: RoomGeometry) -> Point3D {
        var m = p
        switch surface {
        case .floor: m.z = -p.z
        case .ceiling: m.z = 2 * room.height - p.z
        case .wallFront: m.x = -p.x
        case .wallBack: m.x = 2 * room.length - p.x
        case .wallLeft: m.y = -p.y
        case .wallRight: m.y = 2 * room.width - p.y
        }
        return m
    }

    /// First-order reflection points for one speaker/listener pair, sorted by
    /// arrival time. Points are found by intersecting the image-source →
    /// listener segment with the reflecting plane.
    public static func firstReflections(
        speaker: Point3D,
        listener: Point3D,
        room: RoomGeometry
    ) -> [Reflection] {
        let directDistance = speaker.distance(to: listener)
        var reflections: [Reflection] = []

        for surface in Surface.allCases {
            let image = mirror(speaker, across: surface, in: room)
            let pathLength = image.distance(to: listener)

            // Parametric intersection of image→listener with the plane.
            let t: Double
            switch surface {
            case .floor:
                guard listener.z != image.z else { continue }
                t = (0 - image.z) / (listener.z - image.z)
            case .ceiling:
                guard listener.z != image.z else { continue }
                t = (room.height - image.z) / (listener.z - image.z)
            case .wallFront:
                guard listener.x != image.x else { continue }
                t = (0 - image.x) / (listener.x - image.x)
            case .wallBack:
                guard listener.x != image.x else { continue }
                t = (room.length - image.x) / (listener.x - image.x)
            case .wallLeft:
                guard listener.y != image.y else { continue }
                t = (0 - image.y) / (listener.y - image.y)
            case .wallRight:
                guard listener.y != image.y else { continue }
                t = (room.width - image.y) / (listener.y - image.y)
            }
            guard t > 0, t < 1 else { continue }

            let point = Point3D(
                x: image.x + t * (listener.x - image.x),
                y: image.y + t * (listener.y - image.y),
                z: image.z + t * (listener.z - image.z)
            )
            let delayMs = (pathLength - directDistance) / speedOfSound * 1_000
            reflections.append(Reflection(
                surface: surface,
                point: point,
                pathLength: pathLength,
                delayAfterDirectMs: delayMs
            ))
        }
        return reflections.sorted { $0.delayAfterDirectMs < $1.delayAfterDirectMs }
    }

    /// Reflections arriving inside the perceptually critical early window
    /// (< 20 ms after direct sound) — the primary treatment targets.
    public static func criticalReflections(
        speaker: Point3D,
        listener: Point3D,
        room: RoomGeometry,
        windowMs: Double = 20
    ) -> [Reflection] {
        firstReflections(speaker: speaker, listener: listener, room: room)
            .filter { $0.delayAfterDirectMs <= windowMs }
    }
}
