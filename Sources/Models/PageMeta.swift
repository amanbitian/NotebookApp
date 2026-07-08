import Foundation

/// The synced sidecar for one page (`pages/<pageUUID>/meta.json`). Together with
/// `drawing.data`, this is one of exactly two files per page that reach the sync
/// surface — see SYSTEM_DESIGN.md §3.1.
struct PageMeta: Codable, Equatable {
    var lastModified: Date
    var deviceID: String
    /// SHA-256 of the serialized `drawing.data` bytes. Triple duty: journal change
    /// detection, thumbnail cache key, sync-state comparison (§5 note 5).
    var contentHash: String
    var annotations: [Annotation]

    init(lastModified: Date = Date(), deviceID: String, contentHash: String, annotations: [Annotation] = []) {
        self.lastModified = lastModified
        self.deviceID = deviceID
        self.contentHash = contentHash
        self.annotations = annotations
    }
}
