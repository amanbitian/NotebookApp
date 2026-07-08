import Foundation

/// The manifest is the single most critical file in a `.notepkg` package: it defines
/// notebook identity, page order, and format version. See SYSTEM_DESIGN.md §4.
///
/// `updatedAt` is informational only — conflict adjudication must never use it.
/// Per-page `lastModified` + `deviceID` in each page's `PageMeta` is authoritative.
struct Manifest: Codable, Equatable {

    struct SourceDocument: Codable, Equatable {
        var type: SourceType
        var file: String
        var sha256: String

        enum SourceType: String, Codable {
            case pdf
            case none
        }
    }

    struct SchemaInfo: Codable, Equatable {
        var drawingFormat: String
        var annotationFormat: Int
    }

    /// Bump only with an accompanying migration path. An app that reads a manifest with
    /// a higher `formatVersion` than it understands must open the notebook read-only.
    static let currentFormatVersion = 1

    var formatVersion: Int
    var notebookID: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var source: SourceDocument
    var pageOrder: [UUID]
    var schema: SchemaInfo

    init(
        notebookID: UUID = UUID(),
        title: String,
        source: SourceDocument,
        pageOrder: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.formatVersion = Manifest.currentFormatVersion
        self.notebookID = notebookID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.source = source
        self.pageOrder = pageOrder
        self.schema = SchemaInfo(drawingFormat: "pencilkit", annotationFormat: 1)
    }
}

/// Thrown when a manifest declares a `formatVersion` this build does not understand.
/// Per §4 rule 1, the caller must open the notebook read-only and prompt for an app update —
/// never attempt to write into a format version it doesn't fully understand.
struct UnsupportedManifestFormatError: Error {
    let foundVersion: Int
    let supportedVersion: Int = Manifest.currentFormatVersion
}

enum ManifestCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Decodes a manifest, enforcing the format-version gate from §4 rule 1 before
    /// the caller can do anything with the result.
    static func decode(_ data: Data) throws -> Manifest {
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.formatVersion <= Manifest.currentFormatVersion else {
            throw UnsupportedManifestFormatError(foundVersion: manifest.formatVersion)
        }
        return manifest
    }

    static func encode(_ manifest: Manifest) throws -> Data {
        try encoder.encode(manifest)
    }
}
