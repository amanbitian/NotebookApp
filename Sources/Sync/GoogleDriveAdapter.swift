import Foundation

/// Seam for whatever OAuth flow supplies a valid Drive access token (`drive.file`
/// scope only, so the app never requests Google's restricted-scope security
/// assessment). A concrete implementation can use `ASWebAuthenticationSession`,
/// Google Sign-In, or a refresh-token exchange.
protocol GoogleAuthTokenProviding: AnyObject {
    func validAccessToken() async throws -> String
}

final class StaticGoogleAuthTokenProvider: GoogleAuthTokenProviding {
    private let accessToken: String

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    func validAccessToken() async throws -> String {
        accessToken
    }
}

enum GoogleDriveError: Error {
    case tokenUnavailable
    case uploadSessionMissing
    case uploadFailed(statusCode: Int)
}

final class GoogleDriveAdapter: PushSyncAdapter {
    let cloud: SyncCloud = .gdrive

    private let tokenProvider: GoogleAuthTokenProviding
    private let session: URLSession

    init(tokenProvider: GoogleAuthTokenProviding, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func uploadPage(notebookID: UUID, packageURL: URL, pageID: String, contentHash: String) async throws {}

    func uploadManifest(notebookID: UUID, packageURL: URL) async throws {}

    func backupFlattenedPDF(pdfData: Data, fileName: String) async throws {
        let fileURL = try writeTemporaryUploadFile(data: pdfData, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await backupFlattenedPDF(fileURL: fileURL, fileName: fileName)
    }

    func backupFlattenedPDF(fileURL: URL, fileName: String) async throws {
        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: "application/pdf")
    }

    func backupZippedPackage(zipData: Data, fileName: String) async throws {
        let fileURL = try writeTemporaryUploadFile(data: zipData, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await backupZippedPackage(fileURL: fileURL, fileName: fileName)
    }

    func backupZippedPackage(fileURL: URL, fileName: String) async throws {
        try await uploadFile(fileURL: fileURL, fileName: fileName, mimeType: "application/zip")
    }

    private func uploadFile(fileURL: URL, fileName: String, mimeType: String) async throws {
        let accessToken: String
        do {
            accessToken = try await tokenProvider.validAccessToken()
        } catch {
            throw GoogleDriveError.tokenUnavailable
        }

        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        let metadata = (try? JSONSerialization.data(withJSONObject: ["name": fileName])) ?? Data()

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        if let fileSize {
            request.setValue(fileSize.stringValue, forHTTPHeaderField: "X-Upload-Content-Length")
        }
        request.httpBody = metadata

        let (_, sessionResponse) = try await session.data(for: request)
        guard let sessionHTTP = sessionResponse as? HTTPURLResponse,
              (200...299).contains(sessionHTTP.statusCode) else {
            let statusCode = (sessionResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleDriveError.uploadFailed(statusCode: statusCode)
        }
        guard let uploadURL = sessionHTTP.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw GoogleDriveError.uploadSessionMissing
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if let fileSize {
            uploadRequest.setValue(fileSize.stringValue, forHTTPHeaderField: "Content-Length")
        }

        let (_, uploadResponse) = try await session.upload(for: uploadRequest, fromFile: fileURL)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
              (200...299).contains(uploadHTTP.statusCode) else {
            let statusCode = (uploadResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleDriveError.uploadFailed(statusCode: statusCode)
        }
    }

    private func writeTemporaryUploadFile(data: Data, fileName: String) throws -> URL {
        let pathExtension = (fileName as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}
