import SwiftUI

@main
struct NotebookApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            NotebookListView(library: library)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Backgrounding flushes immediately, bypassing the debounce — one of the
            // two moments users lose data in badly built apps (§5 note 4).
            guard newPhase == .background else { return }
            Task { await library.flushAllOpenImmediately() }
        }
    }
}
