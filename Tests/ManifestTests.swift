import XCTest
@testable import NotebookApp

final class ManifestTests: XCTestCase {

    func testRoundTripPreservesAllFields() throws {
        let pageA = UUID()
        let pageB = UUID()
        let manifest = Manifest(
            title: "Signals & Systems",
            source: .init(type: .pdf, file: "source.pdf", sha256: "abc123"),
            pageOrder: [pageA, pageB]
        )

        let data = try ManifestCoding.encode(manifest)
        let decoded = try ManifestCoding.decode(data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.pageOrder, [pageA, pageB])
    }

    /// §4 rule 1: an app reading a manifest with a higher `formatVersion` than it
    /// understands must refuse to treat it as a normal manifest.
    func testFutureFormatVersionIsRejected() throws {
        var manifest = Manifest(title: "Future", source: .init(type: .none, file: "", sha256: ""))
        manifest.formatVersion = Manifest.currentFormatVersion + 1
        let data = try ManifestCoding.encode(manifest)

        XCTAssertThrowsError(try ManifestCoding.decode(data)) { error in
            guard let formatError = error as? UnsupportedManifestFormatError else {
                XCTFail("Expected UnsupportedManifestFormatError, got \(error)")
                return
            }
            XCTAssertEqual(formatError.foundVersion, Manifest.currentFormatVersion + 1)
        }
    }

    /// §3.1: page identity lives in filenames (UUIDs); order lives only in the
    /// manifest. Reordering must not touch page identity.
    func testReorderingPagesDoesNotChangeIdentity() {
        let pageA = UUID()
        let pageB = UUID()
        var manifest = Manifest(title: "T", source: .init(type: .none, file: "", sha256: ""), pageOrder: [pageA, pageB])
        manifest.pageOrder = [pageB, pageA]

        XCTAssertEqual(Set(manifest.pageOrder), Set([pageA, pageB]))
        XCTAssertEqual(manifest.pageOrder, [pageB, pageA])
    }
}
