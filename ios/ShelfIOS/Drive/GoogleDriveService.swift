import Foundation

/// Represents a file or folder in Google Drive
struct DriveItem: Identifiable, Equatable {
    let id: String          // Drive file ID
    let name: String
    let mimeType: String
    let size: Int64?        // nil for folders
    let modifiedTime: Date?

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var isMediaFile: Bool {
        mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/") ||
        name.hasSuffix(".m4b") || name.hasSuffix(".m4a") || name.hasSuffix(".mp3") ||
        name.hasSuffix(".mp4") || name.hasSuffix(".mov") || name.hasSuffix(".mkv") ||
        name.hasSuffix(".avi") || name.hasSuffix(".webm")
    }
}

/// Google Drive API client — lists folders and audio files, downloads files.
/// Uses raw URLSession (no GoogleAPIClientForREST dependency). Every call takes a
/// `DriveCredential`.
class GoogleDriveService {

    private let baseURL = "https://www.googleapis.com/drive/v3"
    private let auth: GoogleAuthService

    /// Ephemeral session: no cookie jar, no cache, nothing persisted between launches.
    private static let apiSession = URLSession(configuration: .ephemeral)

    init(auth: GoogleAuthService) {
        self.auth = auth
    }

    // MARK: - Credentials

    /// The credential to use for a library: the signed-in user's token
    func credential(for library: Library?) async -> DriveCredential? {
        await oauthCredential()
    }

    /// The signed-in user's token, refreshed if needed
    func oauthCredential() async -> DriveCredential? {
        await auth.refreshTokenIfNeeded().map { .bearer($0) }
    }

    // MARK: - List Folders

    /// Lists folders inside a parent folder (or root if parentId is "root")
    func listFolders(in parentId: String, credential: DriveCredential) async throws -> [DriveItem] {
        let query = "'\(parentId)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        return try await listItems(query: query, orderBy: "name", credential: credential)
    }

    // MARK: - List Media Files

    /// Lists audio and video files inside a folder (flat, no recursion)
    func listMediaFiles(in folderId: String, credential: DriveCredential) async throws -> [DriveItem] {
        // Match common audiobook and video formats by MIME type
        let mimeTypes = [
            // Audio
            "audio/mpeg",           // .mp3
            "audio/mp4",            // .m4a, .m4b (most systems)
            "audio/x-m4b",          // .m4b (some systems)
            "audio/x-m4a",          // .m4a variant
            "audio/aac",            // .aac
            "audio/ogg",            // .ogg
            "audio/flac",           // .flac
            // Video
            "video/mp4",            // .mp4
            "video/quicktime",      // .mov
            "video/x-matroska",     // .mkv
            "video/x-msvideo",      // .avi
            "video/webm",           // .webm
        ]
        let mimeFilter = mimeTypes.map { "mimeType = '\($0)'" }.joined(separator: " or ")
        // Also match by filename extension — Drive sometimes reports M4B files as
        // video/mp4 or application/octet-stream instead of audio/*
        let extFilter = "name contains '.m4b' or name contains '.m4a' or name contains '.mp3' or name contains '.flac' or name contains '.mp4' or name contains '.mov' or name contains '.mkv' or name contains '.avi' or name contains '.webm'"
        let query = "'\(folderId)' in parents and (\(mimeFilter) or \(extFilter)) and trashed = false"
        return try await listItems(query: query, orderBy: "name", credential: credential)
    }

    // MARK: - Recursive Media File Listing

    /// Lists audio and video files recursively in a folder and all its subfolders.
    /// Returns tuples of (file, subfolderName) where subfolderName is the immediate parent folder name
    /// (nil for files in the root folder).
    func listMediaFilesRecursive(in folderId: String, credential: DriveCredential) async throws -> [(file: DriveItem, subfolder: String?)] {
        // The root's files and its subfolder list are independent requests
        async let rootFilesRequest = listMediaFiles(in: folderId, credential: credential)
        async let subfoldersRequest = listFolders(in: folderId, credential: credential)

        var results: [(file: DriveItem, subfolder: String?)] = try await rootFilesRequest.map { ($0, nil) }
        let subfolders = try await subfoldersRequest
        guard !subfolders.isEmpty else { return results }

        // Drive has no "list a whole tree" call, so each subfolder costs its own requests.
        // Run a few at a time instead of one after another; a library with one folder
        // per book used to take 2N sequential round trips.
        let maxConcurrent = 4
        try await withThrowingTaskGroup(of: [(file: DriveItem, subfolder: String?)].self) { group in
            var nextIndex = 0

            func enqueue(_ folder: DriveItem) {
                group.addTask {
                    let subFiles = try await self.listMediaFilesRecursive(in: folder.id, credential: credential)
                    // Use this folder's name if the file came from the immediate subfolder,
                    // otherwise preserve the deeper subfolder name
                    return subFiles.map { ($0.file, $0.subfolder ?? folder.name) }
                }
            }

            while nextIndex < min(maxConcurrent, subfolders.count) {
                enqueue(subfolders[nextIndex])
                nextIndex += 1
            }

            while let batch = try await group.next() {
                results.append(contentsOf: batch)
                if nextIndex < subfolders.count {
                    enqueue(subfolders[nextIndex])
                    nextIndex += 1
                }
            }
        }

        return results
    }

    // MARK: - Download File

    /// Returns a download URL for a Drive file (uses alt=media)
    func downloadURL(for fileId: String) -> URL {
        URL(string: "\(baseURL)/files/\(fileId)?alt=media")!
    }

    // MARK: - Stream URL Resolution

    /// Pre-resolves the final streaming URL for a Drive file.
    /// Drive redirects alt=media to signed googleusercontent.com URLs.
    /// AVURLAsset strips auth headers on cross-origin redirects, so we resolve first.
    ///
    /// Uses a redirect-intercepting delegate to capture the 302 Location header
    /// without following the redirect or downloading any file data.
    static func resolveStreamURL(for fileId: String, credential: DriveCredential) async -> URL? {
        // Plain media URL; `apply` adds the token header or the key parameter
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        credential.apply(to: &request)
        request.timeoutInterval = 10
        // If Drive serves the bytes directly instead of redirecting, this must not pull
        // the whole file just to learn the URL. One byte is enough to see the answer.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        // Ephemeral session — isolated connection pool, no caching, no shared state
        let interceptor = RedirectInterceptor()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: interceptor,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            // The delegate blocks the redirect, so this completes with the 302 response body
            // (typically empty or a small HTML stub) — no file data is downloaded.
            let (data, response) = try await session.data(for: request)

            if let redirectURL = interceptor.redirectURL {
                print("[Shelf] resolveStreamURL: resolved \(fileId) → \(redirectURL.host ?? "?")")
                return redirectURL
            }

            // No redirect happened — log the status and reason for diagnosis
            if let http = response as? HTTPURLResponse {
                // Extract Google's error reason from the JSON response, or the raw body
                var reason = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    reason = " — \(message)"
                } else if http.statusCode >= 400, let body = String(data: data.prefix(400), encoding: .utf8) {
                    reason = " — body: \(body.replacingOccurrences(of: "\n", with: " "))"
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
                print("[Shelf] resolveStreamURL: no redirect for \(fileId), HTTP \(http.statusCode), \(contentType)\(reason)")
            }
        } catch {
            print("[Shelf] resolveStreamURL: failed for \(fileId) — \(error.localizedDescription)")
        }

        return nil  // No redirect or failed — caller falls back to auth headers
    }

    // MARK: - Private

    private func listItems(query: String, orderBy: String, credential: DriveCredential) async throws -> [DriveItem] {
        var allItems: [DriveItem] = []
        var pageToken: String? = nil

        repeat {
            var components = URLComponents(string: "\(baseURL)/files")!
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"),
                URLQueryItem(name: "orderBy", value: orderBy),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            credential.apply(to: &request)

            let (data, response) = try await Self.apiSession.data(for: request)
            try Self.checkResponse(response, data: data)

            let result = try JSONDecoder.driveDecoder.decode(DriveListResponse.self, from: data)

            let items = result.files.map { file in
                DriveItem(
                    id: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    size: file.size.flatMap { Int64($0) },
                    modifiedTime: file.modifiedTime
                )
            }

            allItems.append(contentsOf: items)
            pageToken = result.nextPageToken
        } while pageToken != nil

        return allItems
    }

    /// Turns a non-200 response into a `DriveError` carrying Google's own message
    private static func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            message = error["message"] as? String
        }
        throw DriveError.httpError(http.statusCode, message)
    }
}

// MARK: - API Response Models

private struct DriveListResponse: Decodable {
    let nextPageToken: String?
    let files: [DriveFile]
}

private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?           // Drive returns size as a string
    let modifiedTime: Date?
}

// MARK: - JSON Decoder

extension JSONDecoder {
    /// Decoder configured for Google Drive API responses
    static let driveDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            // Try with fractional seconds first, then without
            if let date = formatter.date(from: dateStr) {
                return date
            }
            let basicFormatter = ISO8601DateFormatter()
            basicFormatter.formatOptions = [.withInternetDateTime]
            if let date = basicFormatter.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(dateStr)"))
        }
        return decoder
    }()
}

// MARK: - Redirect Interceptor

/// URLSession delegate that captures a redirect URL without following it.
/// When the server responds with 302, this grabs the Location URL and tells
/// URLSession to stop — no redirect is followed, no file data is downloaded.
private final class RedirectInterceptor: NSObject, URLSessionTaskDelegate {
    /// The redirect destination captured from the 302 response
    var redirectURL: URL?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Capture the redirect target
        redirectURL = request.url
        // Pass nil to cancel the redirect — task completes with the 302 response
        completionHandler(nil)
    }
}

// MARK: - Errors

enum DriveError: LocalizedError {
    case notAuthenticated
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to Google. Please sign in again."
        case .httpError(let code, let message):
            return "Google Drive error (HTTP \(code))\(message.map { ": \($0)" } ?? "")."
        }
    }
}
