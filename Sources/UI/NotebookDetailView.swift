import SwiftUI

struct NotebookDetailView: View {
    @ObservedObject var coordinator: NotebookCoordinator
    let onClose: () -> Void

    @State private var exportJob: ExportJob?
    @State private var showingShareSheet = false
    @State private var exportedURL: URL?

    var body: some View {
        NavigationStack {
            List(coordinator.notebook.pageOrder, id: \.self) { pageID in
                NavigationLink {
                    PageView(notebook: coordinator.notebook, pageID: pageID, coordinator: coordinator)
                } label: {
                    Text("Page \((coordinator.notebook.pageOrder.firstIndex(of: pageID) ?? 0) + 1)")
                }
            }
            .navigationTitle(coordinator.notebook.manifest.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Export PDF") { startExport() }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let exportedURL {
                ShareSheet(activityItems: [exportedURL])
            }
        }
    }

    private func startExport() {
        let job = ExportJob()
        exportJob = job
        job.exportFlattenedPDF(pageOrder: coordinator.notebook.pageOrder, packageURL: coordinator.notebook.packageURL)
        observeExport(job)
    }

    private func observeExport(_ job: ExportJob) {
        Task {
            for await _ in job.$state.values {
                if case .completed(let url) = job.state {
                    exportedURL = url
                    showingShareSheet = true
                    return
                }
                if case .failed = job.state { return }
                if case .cancelled = job.state { return }
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
