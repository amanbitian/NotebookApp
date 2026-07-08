import CoreGraphics
import Foundation

/// A non-ink annotation object (text box, image, shape). Given an app-assigned stable UUID
/// from day one so that annotation-level conflict merging (§7.4, "Later") can be
/// object-identity based rather than value-equality based like ink strokes.
struct Annotation: Codable, Equatable, Identifiable {

    enum Kind: String, Codable {
        case text
        case image
        case shape
    }

    var id: UUID
    var kind: Kind
    var frame: CGRect
    /// Free-form payload: text content for `.text`, asset reference for `.image`, etc.
    var content: String
    var lastModified: Date

    init(id: UUID = UUID(), kind: Kind, frame: CGRect, content: String, lastModified: Date = Date()) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.content = content
        self.lastModified = lastModified
    }
}

extension CGRect: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(CGFloat.self)
        let y = try container.decode(CGFloat.self)
        let width = try container.decode(CGFloat.self)
        let height = try container.decode(CGFloat.self)
        self.init(x: x, y: y, width: width, height: height)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(origin.x)
        try container.encode(origin.y)
        try container.encode(size.width)
        try container.encode(size.height)
    }
}
