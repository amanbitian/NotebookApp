import SwiftUI
import UniformTypeIdentifiers

struct NotebookListView: View {
    @ObservedObject var library: LibraryViewModel
    @State private var showingImporter = false
    @State private var importJob: ImportJob?

    var body: some View {
        Group {
            if let coordinator = library.openCoordinator {
                NotebookDetailView(coordinator: coordinator, onClose: library.close)
            } else {
                NavigationStack {
                    List(library.notebooks) { summary in
                        Button {
                            library.open(summary)
                        } label: {
                            Text(summary.title)
                        }
                    }
                    .navigationTitle("Notebooks")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingImporter = true
                            } label: {
                                Label("Import PDF", systemImage: "plus")
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let title = url.deletingPathExtension().lastPathComponent
            importJob = library.importPDF(at: url, title: title)
        }
        .overlay(alignment: .bottom) {
            if let importJob {
                ImportProgressOverlay(job: importJob) {
                    library.rescan()
                    self.importJob = nil
                }
            }
        }
    }
}

private struct ImportProgressOverlay: View {
    @ObservedObject var job: ImportJob
    let onFinished: () -> Void

    var body: some View {
        Group {
            if case .inProgress(let completed, let total) = job.state {
                ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                    Text("Importing…")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .onChange(of: job.state) { _, newState in
            switch newState {
            case .completed, .failed, .cancelled:
                onFinished()
            default:
                break
            }
        }
    }
}
