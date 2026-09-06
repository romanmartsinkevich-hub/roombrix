import Foundation
import SwiftData
import RoombrixGeometry

/// Persisted room: dimensions and marker positions. Manual L×W×H entry is
/// the PRIMARY path (product decision — no geometry feature may depend on
/// LiDAR); a RoomPlan scan, where the device supports it, only pre-fills
/// these same fields.
@Model
final class RoomRecord {
    var name: String
    /// Meters. Length = x (front wall at x = 0, speakers usually near it),
    /// width = y, height = z.
    var length: Double
    var width: Double
    var height: Double
    /// Two speakers (stereo v1), room coordinates in meters.
    var leftSpeakerX: Double
    var leftSpeakerY: Double
    var rightSpeakerX: Double
    var rightSpeakerY: Double
    /// Tweeter height above floor.
    var speakerHeight: Double
    var listenerX: Double
    var listenerY: Double
    /// Ear height, seated.
    var earHeight: Double
    /// 0 = rectangular as entered. A future scan path may raise it; above
    /// RoomGeometry.modalPredictionIrregularityLimit the UI hides modal
    /// predictions and shows measured LF data only.
    var irregularityFactor: Double

    init(
        name: String = "My room",
        length: Double = 5.0,
        width: Double = 4.0,
        height: Double = 2.5
    ) {
        self.name = name
        self.length = length
        self.width = width
        self.height = height
        // Sensible defaults: speakers a third into the room near the front
        // wall, listener on the center line at ~2/3 length.
        self.leftSpeakerX = 0.8
        self.leftSpeakerY = width / 2 - 1.0
        self.rightSpeakerX = 0.8
        self.rightSpeakerY = width / 2 + 1.0
        self.speakerHeight = 1.0
        self.listenerX = length * 0.6
        self.listenerY = width / 2
        self.earHeight = 1.1
        self.irregularityFactor = 0
    }

    var geometry: RoomGeometry {
        RoomGeometry(
            length: length, width: width, height: height,
            irregularityFactor: irregularityFactor
        )
    }

    var speakerPositions: [Point3D] {
        [
            Point3D(x: leftSpeakerX, y: leftSpeakerY, z: speakerHeight),
            Point3D(x: rightSpeakerX, y: rightSpeakerY, z: speakerHeight),
        ]
    }

    var listenerPosition: Point3D {
        Point3D(x: listenerX, y: listenerY, z: earHeight)
    }

    /// Clamp all markers inside the room after dimension edits.
    func clampMarkers() {
        leftSpeakerX = min(max(leftSpeakerX, 0.1), length - 0.1)
        rightSpeakerX = min(max(rightSpeakerX, 0.1), length - 0.1)
        listenerX = min(max(listenerX, 0.1), length - 0.1)
        leftSpeakerY = min(max(leftSpeakerY, 0.1), width - 0.1)
        rightSpeakerY = min(max(rightSpeakerY, 0.1), width - 0.1)
        listenerY = min(max(listenerY, 0.1), width - 0.1)
        speakerHeight = min(max(speakerHeight, 0.2), height - 0.1)
        earHeight = min(max(earHeight, 0.2), height - 0.1)
    }
}
