import PencilKit
import UIKit

/// Builds simple, visually-distinguishable strokes for merge-algorithm tests. Real
/// strokes carry many more points; these are minimal but sufficient to exercise
/// `StrokeIdentity`'s value-equality-with-epsilon comparison.
enum TestStrokeFactory {
    static func stroke(startingAt x: CGFloat, color: UIColor = .black) -> PKStroke {
        let points = (0..<4).map { i in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(i) * 5, y: CGFloat(i) * 5),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: 0
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }
}
