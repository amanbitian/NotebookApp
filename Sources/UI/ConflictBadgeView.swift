import SwiftUI

/// Non-blocking conflict badge (§7.3): resolving is always a user action, never a
/// timeout. Offers exactly the three outcomes the design allows: keep this, keep
/// that, or keep both as two pages.
struct ConflictBadgeView: View {
    @ObservedObject var notebook: Notebook
    let pageID: UUID
    let conflict: PageConflict
    let coordinator: NotebookCoordinator

    @State private var showingActions = false

    var body: some View {
        Button {
            showingActions = true
        } label: {
            Label("Version conflict", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.9), in: Capsule())
        }
        .padding(8)
        .confirmationDialog(
            "This page has a conflicting version from another device.",
            isPresented: $showingActions,
            titleVisibility: .visible
        ) {
            Button("Keep this version") {
                ConflictResolutionActions.keepActive(notebook: notebook, pageID: pageID)
            }
            Button("Keep the other version") {
                ConflictResolutionActions.keepStashed(
                    notebook: notebook, pageID: pageID,
                    journalStore: coordinator.journalStore, packageURL: notebook.packageURL
                )
            }
            Button("Keep both as two pages") {
                ConflictResolutionActions.keepBothAsTwoPages(
                    notebook: notebook, pageID: pageID,
                    journalStore: coordinator.journalStore, packageURL: notebook.packageURL
                )
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
