import PencilKit
import XCTest
@testable import NotebookApp

final class ThreeWayMergeTests: XCTestCase {

    /// The exact scenario from §7.2: erasing is as deliberate as writing, so a merge
    /// must not resurrect a stroke one branch deliberately erased just because the
    /// other branch happened to add something unrelated.
    ///
    /// base:  {A, B, C}
    /// mine:  erases B  → {A, C}
    /// theirs: adds D   → {A, B, C, D}
    /// expected merged: {A, C, D} — B stays gone.
    func testErasureIsNotResurrectedByUnrelatedRemoteAddition() {
        let a = TestStrokeFactory.stroke(startingAt: 0)
        let b = TestStrokeFactory.stroke(startingAt: 100)
        let c = TestStrokeFactory.stroke(startingAt: 200)
        let d = TestStrokeFactory.stroke(startingAt: 300)

        let base = PKDrawing(strokes: [a, b, c])
        let mine = PKDrawing(strokes: [a, c])
        let theirs = PKDrawing(strokes: [a, b, c, d])

        guard case .merged(let result) = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) else {
            return XCTFail("Expected a clean merge, not a fallback")
        }

        let resultSignatures = Set(result.strokes.map { StrokeIdentity.signature(for: $0) })
        XCTAssertTrue(resultSignatures.contains(StrokeIdentity.signature(for: a)))
        XCTAssertTrue(resultSignatures.contains(StrokeIdentity.signature(for: c)))
        XCTAssertTrue(resultSignatures.contains(StrokeIdentity.signature(for: d)))
        XCTAssertFalse(resultSignatures.contains(StrokeIdentity.signature(for: b)), "Erased stroke B must not be resurrected")
    }

    func testMissingMergeBaseFallsBack() {
        let mine = PKDrawing(strokes: [TestStrokeFactory.stroke(startingAt: 0)])
        let theirs = PKDrawing(strokes: [TestStrokeFactory.stroke(startingAt: 100)])

        guard case .fallback(let reason) = ThreeWayMerge.merge(base: nil, mine: mine, theirs: theirs) else {
            return XCTFail("Expected fallback when merge base is missing")
        }
        XCTAssertEqual(reason, .missingMergeBase)
    }

    func testIndependentAdditionsFromBothBranchesMergeCleanly() {
        let a = TestStrokeFactory.stroke(startingAt: 0)
        let mine = TestStrokeFactory.stroke(startingAt: 50)
        let theirs = TestStrokeFactory.stroke(startingAt: 150)

        let base = PKDrawing(strokes: [a])
        let mineDrawing = PKDrawing(strokes: [a, mine])
        let theirsDrawing = PKDrawing(strokes: [a, theirs])

        guard case .merged(let result) = ThreeWayMerge.merge(base: base, mine: mineDrawing, theirs: theirsDrawing) else {
            return XCTFail("Expected a clean merge")
        }
        XCTAssertEqual(result.strokes.count, 3)
    }

    /// §7.3 "partial-eraser wrinkle": a base stroke splitting into fragments in one
    /// branch should register as a removal + additions, handled by the same set-diff
    /// logic without special-casing.
    func testPartialEraseRegistersAsRemovalPlusAdditions() {
        let original = TestStrokeFactory.stroke(startingAt: 0)
        let fragmentA = TestStrokeFactory.stroke(startingAt: 0, color: .red)
        let fragmentB = TestStrokeFactory.stroke(startingAt: 400, color: .red)

        let base = PKDrawing(strokes: [original])
        let mine = PKDrawing(strokes: [fragmentA, fragmentB]) // original erased, split into two fragments
        let theirs = PKDrawing(strokes: [original]) // untouched

        guard case .merged(let result) = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) else {
            return XCTFail("Expected a clean merge")
        }
        let signatures = Set(result.strokes.map { StrokeIdentity.signature(for: $0) })
        XCTAssertTrue(signatures.contains(StrokeIdentity.signature(for: fragmentA)))
        XCTAssertTrue(signatures.contains(StrokeIdentity.signature(for: fragmentB)))
    }
}
