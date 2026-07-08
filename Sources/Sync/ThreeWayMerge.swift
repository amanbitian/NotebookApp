import PencilKit

/// The 3-way stroke-level merge from §7.3. A 2-way merge ("union of non-duplicate
/// strokes") resurrects deletions because it can't distinguish "deleted in one branch"
/// from "added in the other" without the common ancestor.
///
/// Rollout note (§7.4): this algorithm ships in v1.1. In v1.0, `ConflictResolver`
/// calls straight into the fallback path without invoking this type, so wiring it in
/// later is additive and doesn't touch anything upstream.
enum ThreeWayMerge {

    enum FallbackReason: Equatable {
        /// Fresh install mid-conflict, or the base was already cleared.
        case missingMergeBase
        /// The same base stroke was removed in both branches while both branches also
        /// added new strokes — the conservative signal for "both sides transformed the
        /// same stroke differently" (§7.3: "both sides lasso-transformed it"). This is
        /// a heuristic, not exact identity tracking — see `StrokeIdentity`. Over-firing
        /// here just asks the user (P4: never silently lose ink), so it's tuned
        /// conservative on purpose.
        case sameStrokeModifiedInBothBranches
        /// Heuristic guard against identity-matching gone wrong: the diff is
        /// implausibly large relative to the page.
        case diffImplausiblyLarge
    }

    enum Outcome {
        case merged(PKDrawing)
        case fallback(FallbackReason)
    }

    static func merge(base: PKDrawing?, mine: PKDrawing, theirs: PKDrawing) -> Outcome {
        guard let base else {
            return .fallback(.missingMergeBase)
        }

        let baseIndex = index(base)
        let mineIndex = index(mine)
        let theirsIndex = index(theirs)

        let baseKeys = Set(baseIndex.keys)
        let mineKeys = Set(mineIndex.keys)
        let theirsKeys = Set(theirsIndex.keys)

        let addedMine = mineKeys.subtracting(baseKeys)
        let removedMine = baseKeys.subtracting(mineKeys)
        let addedTheirs = theirsKeys.subtracting(baseKeys)
        let removedTheirs = baseKeys.subtracting(theirsKeys)

        let removedByBoth = removedMine.intersection(removedTheirs)
        if !removedByBoth.isEmpty, !addedMine.isEmpty, !addedTheirs.isEmpty {
            return .fallback(.sameStrokeModifiedInBothBranches)
        }

        let diffMagnitude = addedMine.count + removedMine.count + addedTheirs.count + removedTheirs.count
        let plausibleCeiling = max(baseKeys.count * 4, 200)
        if diffMagnitude > plausibleCeiling {
            return .fallback(.diffImplausiblyLarge)
        }

        var mergedKeys = baseKeys
        mergedKeys.subtract(removedMine)
        mergedKeys.subtract(removedTheirs)
        mergedKeys.formUnion(addedMine)
        mergedKeys.formUnion(addedTheirs)

        var mergedStrokes: [PKStroke] = []
        mergedStrokes.reserveCapacity(mergedKeys.count)
        for key in mergedKeys {
            if let stroke = baseIndex[key] ?? mineIndex[key] ?? theirsIndex[key] {
                mergedStrokes.append(stroke)
            }
        }

        return .merged(PKDrawing(strokes: mergedStrokes))
    }

    private static func index(_ drawing: PKDrawing) -> [StrokeSignature: PKStroke] {
        var result: [StrokeSignature: PKStroke] = [:]
        result.reserveCapacity(drawing.strokes.count)
        for stroke in drawing.strokes {
            result[StrokeIdentity.signature(for: stroke)] = stroke
        }
        return result
    }
}
