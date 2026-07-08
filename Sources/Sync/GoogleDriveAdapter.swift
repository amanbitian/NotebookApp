import Foundation

/// Seam for whatever OAuth flow supplies a valid Drive access token (`drive.file`
/// scope only, so the app never requests Google's restricted-scope security
/// assessment — §6.4). A concrete implementation (e.g. `ASWebAuthenticationSession` +
/// refresh-token exchange, or the Google Sign-In SDK) is v1.1 scope per §13 and is
/// deliberately not included here — it's orthogonal to this document's storage/sync
/// architecture and doesn't change any type on this side of the seam.
protocol GoogleAuthTokenProviding: AnyObject {
    func validAccessToken() async throws -> String
}

enum GoogleDriveError: Error {
    case tokenUnavailable
    case uploadFailed(statusCode: Int)
}

/// Push-only Google Drive backup (§6.4). Nothing is ever read back from Drive into the
/// live notebook — restore is an explicit user-initiated *import* that creates a new
/// notebook (§6.4, "Restore from Drive"), handled by `ImportJob`, not this adapter.
/// This single one-way constraint eliminates three-way merge across two clouds.
final class GoogleDriveAdapter: PushSyncAdapter {
    let cloud: SyncCloud = .gdrive

    private let tokenProvider: GoogleAuthTokenProviding
    private let session: URLSession

    init(tokenProvider: GoogleAuthTokenProviding, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    /// Drive backups operate at the notebook (export) level, debounced 15 minutes
    /// after last edit, not per page (§6.4) — so per-page calls from `SyncEngine`'s
    /// generic upload loop are no-ops here. `backupFlattenedPDF` / `backupZippedPackage`
    /// are the real entry points, invoked by a separate debounced backup scheduler.
    func uploadPage(notebookID: UUID, packageURL: URL, pageID: String, contentHash: String) async throws {}

    func uploadManifest(notebookID: UUID, packageURL: URL) async throws {}

    /// Backup artifact 1 (§6.4, default): a flattened, universally-readable PDF that
    /// survives the app not existing.
    func backupFlattenedPDF(pdfData: Data, fileName: String) async throws {
        try await uploadFile(data: pdfData, fileName: fileName, mimeType: "application/pdf")
    }

    /// Backup artifact 2 (§6.4, v1.2): a zipped `.notepkg` snapshot for full-fidelity
    /// restore, larger than the flattened PDF.
    func backupZippedPackage(zipData: Data, fileName: String) async throws {
        try await uploadFile(data: zipData, fileName: fileName, mimeType: "application/zip")
    }

    private func uploadFile(data: Data, fileName: String, mimeType: String) async throws {
        let accessToken: String
        do {
            accessToken = try await tokenProvider.validAccessToken()
        } catch {
            // Token refresh failures degrade silently to a "backup pending" badge —
            // never a modal interrupting writing (§6.4, §10).
            throw GoogleDriveError.tokenUnavailable
        }

        let boundary = "notebookapp-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, fileName: fileName, mimeType: mimeType, data: data)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleDriveError.uploadFailed(statusCode: statusCode)
        }
    }

    private func multipartBody(boundary: String, fileName: String, mimeType: String, data: Data) -> Data {
        var body = Data()
        let metadata = (try? JSONSerialization.data(withJSONObject: ["name": fileName])) ?? Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        return body
    }
}
