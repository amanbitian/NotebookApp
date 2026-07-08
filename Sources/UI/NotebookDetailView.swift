import SwiftUI

struct NotebookDetailView: View {
    @ObservedObject var coordinator: NotebookCoordinator
    let onClose: () -> Void
    let onShowLibrary: () -> Void

    @State private var exportJob: ExportJob?
    @State private var showingShareSheet = false
    @State private var exportedURL: URL?
    @State private var showingDriveBackup = false
    @State private var driveAccessToken = ""
    @State private var includeZippedDriveSnapshot = false
    @State private var driveBackupStatus: String?

    var body: some View {
        NavigationStack {
            List(Array(coordinator.notebook.pageOrder.enumerated()), id: \.element) { index, pageID in
                NavigationLink {
                    PageView(notebook: coordinator.notebook, pageID: pageID, coordinator: coordinator)
                } label: {
                    Text("Page \(index + 1)")
                }
            }
            .navigationTitle(coordinator.notebook.manifest.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open", action: onShowLibrary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Export PDF") { startExport() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Drive Backup") { showingDriveBackup = true }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let exportedURL {
                ShareSheet(activityItems: [exportedURL])
            }
        }
        .sheet(isPresented: $showingDriveBackup) {
            DriveBackupSheet(
                accessToken: $driveAccessToken,
                includeZippedSnapshot: $includeZippedDriveSnapshot,
                status: driveBackupStatus,
                onBackup: startDriveBackup
            )
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

    private func startDriveBackup() {
        let token = driveAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            driveBackupStatus = "Paste a Google Drive access token first."
            return
        }

        driveBackupStatus = "Backing up..."
        coordinator.configureGoogleDriveBackup(
            tokenProvider: StaticGoogleAuthTokenProvider(accessToken: token),
            includeZippedPackage: includeZippedDriveSnapshot,
            debounceInterval: 15 * 60
        )

        Task {
            await coordinator.backupToGoogleDriveNow()
            driveBackupStatus = describeDriveBackupState()
        }
    }

    private func describeDriveBackupState() -> String {
        guard let state = coordinator.driveBackupScheduler?.state else {
            return "Drive backup is not configured."
        }
        switch state {
        case .idle:
            return "Drive backup is idle."
        case .scheduled(let date):
            return "Drive backup scheduled for \(date.formatted())."
        case .running:
            return "Drive backup is running..."
        case .pending(let reason):
            return "Backup pending: \(reason)"
        case .completed(let date):
            return "Backup completed at \(date.formatted())."
        }
    }
}

private struct DriveBackupSheet: View {
    @Binding var accessToken: String
    @Binding var includeZippedSnapshot: Bool
    let status: String?
    let onBackup: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Google Drive") {
                    SecureField("Access token", text: $accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Also upload zipped .notepkg", isOn: $includeZippedSnapshot)
                    Button("Back Up Now", action: onBackup)
                }
                if let status {
                    Section("Status") {
                        Text(status)
                    }
                }
            }
            .navigationTitle("Drive Backup")
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
