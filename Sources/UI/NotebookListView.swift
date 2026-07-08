import SwiftUI
import UniformTypeIdentifiers

struct NotebookListView: View {
    @ObservedObject var library: LibraryViewModel
    @State private var showingImporter = false
    @State private var importJob: ImportJob?
    @State private var showingWorkspace = false

    var body: some View {
        Group {
            if showingWorkspace, !library.openCoordinators.isEmpty {
                NotebookWorkspaceView(library: library) {
                    showingWorkspace = false
                }
            } else {
                NavigationStack {
                    List(library.notebooks) { summary in
                        Button {
                            library.open(summary)
                            showingWorkspace = true
                        } label: {
                            HStack {
                                Text(summary.title)
                                Spacer()
                                if library.openCoordinators.contains(where: { $0.notebook.id == summary.id }) {
                                    Text("Open")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("Notebooks")
                    .toolbar {
                        if !library.openCoordinators.isEmpty {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Tabs") {
                                    showingWorkspace = true
                                }
                            }
                        }
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
        .onChange(of: library.openCoordinators.count) { _, count in
            if count == 0 {
                showingWorkspace = false
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let title = url.deletingPathExtension().lastPathComponent
            if isImage(url) {
                importJob = library.importImage(at: url, title: title)
            } else {
                importJob = library.importPDF(at: url, title: title)
            }
        }
        .overlay(alignment: .bottom) {
            if let importJob {
                ImportProgressOverlay(job: importJob) {
                    library.rescan()
                    openImportedNotebookIfNeeded(importJob)
                    self.importJob = nil
                }
            }
        }
    }

    private func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private func openImportedNotebookIfNeeded(_ job: ImportJob) {
        guard case .completed(let packageURL) = job.state else { return }
        library.rescan()
        if let summary = library.notebooks.first(where: { $0.packageURL == packageURL }) {
            library.open(summary)
            showingWorkspace = true
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
