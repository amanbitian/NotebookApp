import XCTest
@testable import NotebookApp

final class AtomicFileWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteCreatesFileWithExpectedContent() throws {
        let url = tempDir.appendingPathComponent("drawing.data")
        let payload = "hello".data(using: .utf8)!

        try AtomicFileWriter.write(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    /// §5 note 3: atomic replace means a crash mid-write leaves the previous intact
    /// version, never a half-written file. We can't simulate a real crash, but we can
    /// verify no temp artifacts survive a successful write and that a second write
    /// fully replaces the first.
    func testOverwriteReplacesContentAndLeavesNoTempArtifacts() throws {
        let url = tempDir.appendingPathComponent("meta.json")
        try AtomicFileWriter.write("first".data(using: .utf8)!, to: url)
        try AtomicFileWriter.write("second".data(using: .utf8)!, to: url)

        XCTAssertEqual(try Data(contentsOf: url), "second".data(using: .utf8)!)

        let siblings = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(siblings, [url])
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let nested = tempDir.appendingPathComponent("pages/\(UUID().uuidString)/drawing.data")
        try AtomicFileWriter.write(Data([0x01, 0x02]), to: nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
