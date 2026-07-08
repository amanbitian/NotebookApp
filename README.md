# NotebookApp — implementation of SYSTEM_DESIGN.md

This is a from-scratch Swift implementation of the architecture in `../SYSTEM_DESIGN.md`
(v2). It was written on Windows, where there is no Swift toolchain, no Xcode, and no
iOS simulator — **none of this code has been compiled, run, or tested.** Treat it as a
careful first draft, not a verified build. See "Known gaps and things to verify first"
below before you trust any of it.

## Build prerequisites (do this on a Mac)

1. macOS with Xcode 15+ installed (Xcode 16 recommended for Swift 5.9 / iOS 17 SDKs).
2. [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`. The
   project is defined as `project.yml`, not a committed `.xcodeproj`, because hand
   authoring a `.pbxproj` on a machine that can't open Xcode is far more error-prone
   than authoring a small, human-readable YAML spec and letting `xcodegen` generate the
   project file correctly.
3. From this directory: `xcodegen generate`. This produces `NotebookApp.xcodeproj`
   and resolves the one SPM dependency ([GRDB.swift](https://github.com/groue/GRDB.swift),
   for the journal and search databases — see §6 and §8 of the design doc).
4. Open `NotebookApp.xcodeproj`, select a development team under Signing &
   Capabilities (needed for the iCloud entitlements XcodeGen generates from
   `project.yml`), and build for an iPad simulator or device (iOS 16+, deployment
   target set in `project.yml`).
5. Run the `NotebookAppTests` scheme to run the unit test suite in `Tests/`.

If you don't want the iCloud entitlement (e.g. to just build and poke at it locally
first), delete the `entitlements:` block from `project.yml` before running
`xcodegen generate` — the app degrades to local-only storage per P1 (local editing
never depends on network/account state), it just won't sync anywhere.

## What's here, mapped to the design doc

| Design doc section | Code |
|---|---|
| §3 storage layout | `Sources/Storage/PackageLayout.swift`, `NotebookPackage.swift` |
| §4 manifest | `Sources/Models/Manifest.swift` |
| §5 autosave pipeline, undo | `Sources/DocumentEngine/` |
| §6 sync engine | `Sources/Sync/JournalStore.swift`, `SyncEngine.swift`, `SyncTypes.swift`, `ICloudSyncAdapter.swift`, `GoogleDriveAdapter.swift` |
| §7 conflict resolution | `Sources/Sync/ThreeWayMerge.swift`, `ConflictResolver.swift`, `StrokeIdentity.swift`, `MergeBaseStore.swift`, `ConflictVersionStore.swift`, `ConflictResolutionActions.swift` |
| §8 search/indexing | `Sources/Search/IndexStore.swift`, `IndexingPipeline.swift` |
| §9 import/export | `Sources/ImportExport/ImportJob.swift`, `ExportJob.swift` |
| §2 UI layer + wiring | `Sources/UI/`, `App/NotebookApp.swift` |
| §10/§11 failure modes, targets | Addressed inline where the relevant mechanism lives (see comments referencing `§10`/`§11` in each file) |

Every non-trivial type has a doc comment citing the design doc section it implements,
so `grep -rn "§"  Sources` is a reasonable way to cross-reference code back to spec.

## Rollout phasing implemented (§7.4, §13)

This build targets **v1.0 + the v1.1 mechanism, gated off**:

- v1.0 surface (detection + both-versions-kept conflict UI, journal, checkpoints,
  merge-base plumbing, typed-text + PDF-layer search, flattened-PDF export) is fully
  wired.
- The v1.1 three-way merge algorithm (`ThreeWayMerge.swift`) is fully implemented
  per §7.3, including the resurrection-prevention test case from §7.2. It is wired
  into `ConflictResolver` behind `SyncEngine.mergeEnabled`, which defaults to
  `false` — matching §7.4's explicit rollout order ("v1.0 ships... no merge").
  Flip it once the merge path has been validated against real device behavior.

## Known gaps and things to verify first

Because nothing here has run, prioritize verification in roughly this order:

1. **Compile it.** `xcodegen generate` + build in Xcode first — there will almost
   certainly be small API-signature mismatches (PencilKit/PDFKit/GRDB APIs drift
   across SDK versions and I could not check against a live SDK).
2. **`ICloudSyncAdapter`** (§6.3) is the least-tested design in here: `NSMetadataQuery`
   lifecycle (gathering vs. live-update phases), `NSFileCoordinator` interaction with
   the iCloud daemon, and `NSFileVersion`-based conflict surfacing are all areas real
   device testing against two paired devices/simulators will very likely surface
   issues in. Treat `startObservingChanges`/`handleQueryUpdate` as a first draft of
   the control flow, not a hardened implementation.
3. **`StrokeIdentity` / `ThreeWayMerge`** heuristics (§7.3) — the quantization epsilon
   and downsampled point count are guesses, not tuned against real handwriting data.
   The unit tests in `Tests/ThreeWayMergeTests.swift` verify the *algorithm's* logic
   (the doc's own resurrection example, partial-erase handling) but can't validate the
   signature's real-world false-positive/false-negative rate — that needs actual
   PencilKit strokes from a device.
4. **Not implemented — deliberately deferred per §13 phasing:**
   - Google OAuth token acquisition (`GoogleAuthTokenProviding` is a protocol seam
     only — no concrete `ASWebAuthenticationSession`/Google Sign-In implementation).
     v1.1 scope.
   - Handwriting OCR (`IndexingPipeline.runHandwritingOCR` is a stub returning `[]`).
     v1.2 scope.
   - Zipped `.notepkg` Drive snapshots (`GoogleDriveAdapter.backupZippedPackage`
     exists and works, but nothing calls it yet — no zip-creation code). v1.2 scope.
   - Annotation-level conflict merging (only both-versions-kept fallback for
     annotations today). "Later" per §7.4.
   - DOCX/PPTX import (`ImportJob.importOfficeDocument` throws
     `ImportError.unsupportedFormat`). v2.x scope.
5. **UI layer** (`Sources/UI/`) is a functional but minimal shell — enough to exercise
   the architecture end to end (import → open → draw → autosave → sync → export), not
   a polished product UI. Toolbar, ink color/width picker, page thumbnails/grid view,
   and template/paper selection (mentioned in §5's undo scope table) don't exist yet.

## Running the tests

`Tests/` covers the load-bearing, non-UI logic that's cheapest to get wrong silently:
manifest format-version gating, atomic-write behavior, the journal/checkpoint diff
that drives uploads, the sync state machine's transition rules, the three-way merge
algorithm (including the doc's own erasure-resurrection example), conflict detection's
clean-vs-dirty distinction, and FTS5 search upsert/rebuild semantics. It does not
cover PencilKit UI interaction, iCloud's actual network behavior, or Google Drive's
actual API responses — those need device/integration testing, not unit tests.
