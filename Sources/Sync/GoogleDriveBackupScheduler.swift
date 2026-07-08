import Combine
import Foundation

@MainActor
final class GoogleDriveBackupScheduler: ObservableObject {
    enum State: Equatable {
        case idle
        case scheduled(Date)
        case running
        case pending(String)
        case completed(Date)
    }

    struct Options {
        var includeFlattenedPDF = true
        var includeZippedPackage = false
        var debounceInterval: TimeInterval = 15 * 60
    }

    @Published private(set) var state: State = .idle

    private let adapter: GoogleDriveAdapter
    private let packageURL: URL
    private var pageOrder: [UUID]
    private var options: Options
    private var scheduledTask: Task<Void, Never>?

    init(adapter: GoogleDriveAdapter, packageURL: URL, pageOrder: [UUID], options: Options = Options()) {
        self.adapter = adapter
        self.packageURL = packageURL
        self.pageOrder = pageOrder
        self.options = options
    }

    func update(pageOrder: [UUID], options: Options? = nil) {
        self.pageOrder = pageOrder
        if let options {
            self.options = options
        }
    }

    func scheduleAfterEdit() {
        scheduledTask?.cancel()
        let runAt = Date().addingTimeInterval(options.debounceInterval)
        state = .scheduled(runAt)
        scheduledTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(options.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.backupNow()
        }
    }

    func backupNow() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        state = .running

        do {
            let artifacts = try await Self.buildArtifacts(
                packageURL: packageURL,
                pageOrder: pageOrder,
                includeFlattenedPDF: options.includeFlattenedPDF,
                includeZippedPackage: options.includeZippedPackage
            )
            defer {
                for artifact in artifacts {
                    try? FileManager.default.removeItem(at: artifact.fileURL)
                }
            }

            for artifact in artifacts {
                switch artifact.kind {
                case .flattenedPDF:
                    try await adapter.backupFlattenedPDF(fileURL: artifact.fileURL, fileName: artifact.fileName)
                case .zippedPackage:
                    try await adapter.backupZippedPackage(fileURL: artifact.fileURL, fileName: artifact.fileName)
                }
            }
            state = .completed(Date())
        } catch {
            state = .pending(String(describing: error))
        }
    }

    private enum ArtifactKind {
        case flattenedPDF
        case zippedPackage
    }

    private struct BackupArtifact {
        let kind: ArtifactKind
        let fileURL: URL
        let fileName: String
    }

    private nonisolated static func buildArtifacts(
        packageURL: URL,
        pageOrder: [UUID],
        includeFlattenedPDF: Bool,
        includeZippedPackage: Bool
    ) async throws -> [BackupArtifact] {
        try await Task.detached(priority: .utility) {
            var artifacts: [BackupArtifact] = []
            let baseName = packageURL.deletingPathExtension().lastPathComponent

            if includeFlattenedPDF {
                let pdfURL = try ExportJob.renderPDFFile(
                    pageOrder: pageOrder,
                    packageURL: packageURL,
                    exportScale: 2.0,
                    progress: { _ in },
                    isCancelled: { Task.isCancelled }
                )
                artifacts.append(BackupArtifact(kind: .flattenedPDF, fileURL: pdfURL, fileName: "\(baseName).pdf"))
            }

            if includeZippedPackage {
                let zipURL = try PackageSnapshotBuilder.makeZippedSnapshot(packageURL: packageURL)
                artifacts.append(BackupArtifact(kind: .zippedPackage, fileURL: zipURL, fileName: "\(baseName).notepkg.zip"))
            }

            return artifacts
        }.value
    }
}
