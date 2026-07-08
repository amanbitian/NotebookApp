import CoreGraphics
import PencilKit
import UIKit

/// `PKStroke` exposes no stable public identifier, so "same stroke" for 3-way diffing
/// purposes is value equality over ink type, transform, and path control points,
/// compared with an epsilon on coordinates (§7.3). This is the pragmatic reality of
/// building on PencilKit rather than a custom ink engine.
///
/// Full-resolution point-by-point comparison would be O(points) per stroke and this
/// signature needs to be hashable for set-diffing, so points are quantized and
/// downsampled to a bounded number of samples rather than compared exactly. This
/// trades a small chance of misidentifying two near-identical strokes as equal for
/// bounded cost — an acceptable tradeoff because the fallback path (§7.3) exists
/// precisely to catch cases where identity matching goes wrong.
struct StrokeSignature: Hashable {
    fileprivate let inkType: String
    fileprivate let colorComponents: [Int16]
    fileprivate let transformComponents: [Int32]
    fileprivate let pointCount: Int
    fileprivate let sampledPoints: [Int32]
}

enum StrokeIdentity {
    /// Coordinate quantization step, in points. Two control points within half a point
    /// of each other are treated as identical for signature purposes.
    static let coordinateEpsilon: CGFloat = 0.5
    private static let sampleCount = 12

    static func signature(for stroke: PKStroke) -> StrokeSignature {
        let ink = stroke.ink
        let t = stroke.transform
        let transformComponents = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { quantize($0, epsilon: 0.01) }
        let colorComponents = quantizedColor(ink.color)

        let points = Array(stroke.path)
        let sampled = sample(points, count: sampleCount).flatMap { point -> [Int32] in
            [quantize(point.location.x, epsilon: coordinateEpsilon), quantize(point.location.y, epsilon: coordinateEpsilon)]
        }

        return StrokeSignature(
            inkType: ink.inkType.rawValue,
            colorComponents: colorComponents,
            transformComponents: transformComponents,
            pointCount: points.count,
            sampledPoints: sampled
        )
    }

    private static func sample(_ points: [PKStrokePoint], count: Int) -> [PKStrokePoint] {
        guard points.count > count else { return points }
        var result: [PKStrokePoint] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let index = (i * (points.count - 1)) / max(count - 1, 1)
            result.append(points[index])
        }
        return result
    }

    private static func quantize(_ value: CGFloat, epsilon: CGFloat) -> Int32 {
        Int32((value / epsilon).rounded())
    }

    private static func quantizedColor(_ color: UIColor) -> [Int16] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int16(($0 * 255).rounded()) }
    }
}
