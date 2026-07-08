import Foundation

/// Per-file sync state machine, one instance per (cloud, page) — §6.2.
///
/// ```
///       ┌────────────────────────────────────────┐
///       ▼                                        │
///     idle ──write──▶ dirty ──picked up──▶ uploading ──ok──▶ synced ─┐
///                       ▲                    │                       │
///                       │                 remote                     │
///                    resolved             changed                    │
///                       │                    ▼                       │
///                       └───────────── conflict                      │
///                                                                    │
///     ◀───────────────────────────────────────────────────────────────
/// ```
enum PageSyncState: String, Codable {
    case idle
    case dirty
    case uploading
    case synced
    case conflict

    /// Valid transitions, enforced by `SyncStateMachine` so callers can't wedge a page
    /// into an inconsistent state.
    func canTransition(to next: PageSyncState) -> Bool {
        switch (self, next) {
        case (.idle, .dirty): return true
        case (.dirty, .uploading): return true
        case (.uploading, .synced): return true
        case (.uploading, .conflict): return true
        case (.synced, .dirty): return true
        case (.synced, .conflict): return true
        case (.conflict, .dirty): return true // resolved
        case (.uploading, .dirty): return true // upload failed, retry from dirty
        default: return false
        }
    }
}

enum SyncStateError: Error {
    case invalidTransition(from: PageSyncState, to: PageSyncState)
}

/// Drives per-(cloud, page) state transitions and persists them, so a crash mid-upload
/// resumes rather than re-uploads (§6.2).
final class SyncStateMachine {
    private let journalStore: JournalStore
    private let cloud: SyncCloud
    private let notebookID: UUID

    init(journalStore: JournalStore, cloud: SyncCloud, notebookID: UUID) {
        self.journalStore = journalStore
        self.cloud = cloud
        self.notebookID = notebookID
    }

    func currentState(pageID: String) throws -> PageSyncState {
        try journalStore.state(cloud: cloud, notebookID: notebookID, pageID: pageID)
    }

    @discardableResult
    func transition(pageID: String, to next: PageSyncState) throws -> PageSyncState {
        let current = try currentState(pageID: pageID)
        guard current.canTransition(to: next) else {
            throw SyncStateError.invalidTransition(from: current, to: next)
        }
        try journalStore.setState(next, cloud: cloud, notebookID: notebookID, pageID: pageID)
        return next
    }
}
