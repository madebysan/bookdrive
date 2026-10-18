import Foundation
import Combine

/// Tracks the download progress of a single file
struct DownloadProgress: Identifiable {
    let id: String          // Drive file ID
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64 = 0
    var fraction: Double { totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0 }
    var isComplete: Bool = false
    var error: String?
}

/// Singleton registry for passing background URLSession completion handlers from AppDelegate to DownloadManager
class BackgroundSessionRegistry {
    static let shared = BackgroundSessionRegistry()
    var completionHandler: (() -> Void)?
    private init() {}
}

/// Manages file downloads from Google Drive with progress tracking.
/// Uses background URLSession so downloads continue when the app is backgrounded or terminated.
@MainActor
class DownloadManager: NSObject, ObservableObject {

    @Published var activeDownloads: [String: DownloadProgress] = [:]
    @Published var queuedCount: Int = 0

    /// Publisher that fires when a download finishes — (driveFileId, localURL?)
    let downloadCompleted = PassthroughSubject<(String, URL?), Never>()

    private var tasks: [Int: String] = [:]  // taskIdentifier -> driveFileId
    private var fileNames: [String: String] = [:]  // driveFileId -> fileName

    /// Background URLSession — survives app termination
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.madebysan.ShelfIOS.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 3600    // 1 hour max for large files
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private let driveService: GoogleDriveService

    init(driveService: GoogleDriveService) {
        self.driveService = driveService
        super.init()

        // Reconnect to any in-progress background tasks from a previous app session
        reconnectToExistingTasks()
    }

    /// The local directory where audiobooks are stored
    nonisolated static var audiobooksDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Audiobooks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads a file from Google Drive and saves it locally.
    /// The download continues in the background even if the app is suspended or terminated.
    func download(driveFileId: String, fileName: String, credential: DriveCredential) {
        // Don't start duplicate downloads
        guard !isDownloading(driveFileId) else { return }

        Task {
            var request = URLRequest(url: driveService.downloadURL(for: driveFileId))
            credential.apply(to: &request)

            let task = session.downloadTask(with: request)
            // Encode driveFileId and fileName in taskDescription so it survives app relaunch
            task.taskDescription = "\(driveFileId):::\(fileName)"

            activeDownloads[driveFileId] = DownloadProgress(id: driveFileId)
            tasks[task.taskIdentifier] = driveFileId
            fileNames[driveFileId] = fileName

            task.resume()
        }
    }

    /// Cancels a download in progress
    func cancel(driveFileId: String) {
        // Find the task by driveFileId
        for (taskId, fileId) in tasks where fileId == driveFileId {
            session.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
            }
            tasks.removeValue(forKey: taskId)
        }
        fileNames.removeValue(forKey: driveFileId)
        activeDownloads.removeValue(forKey: driveFileId)
    }

    /// Whether a file is currently downloading
    func isDownloading(_ driveFileId: String) -> Bool {
        tasks.values.contains(driveFileId)
    }

    /// Deletes a downloaded audiobook file
    static func deleteLocalFile(fileName: String) {
        let path = audiobooksDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: path)
    }

    /// Total size of all downloaded audiobooks
    static func totalDownloadedSize() -> Int64 {
        let dir = audiobooksDirectory
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Reconnect to Background Tasks

    /// Called on init — reconnects to any in-progress background download tasks
    /// that may have been started in a previous app session.
    private func reconnectToExistingTasks() {
        session.getAllTasks { [weak self] existingTasks in
            Task { @MainActor in
                guard let self = self else { return }
                for task in existingTasks {
                    guard let description = task.taskDescription else { continue }
                    let parts = description.components(separatedBy: ":::")
                    guard parts.count == 2 else { continue }

                    let driveFileId = parts[0]
                    let fileName = parts[1]

                    self.tasks[task.taskIdentifier] = driveFileId
                    self.fileNames[driveFileId] = fileName

                    // Restore progress tracking
                    if self.activeDownloads[driveFileId] == nil {
                        var progress = DownloadProgress(id: driveFileId)
                        progress.bytesDownloaded = task.countOfBytesReceived
                        progress.totalBytes = task.countOfBytesExpectedToReceive
                        self.activeDownloads[driveFileId] = progress
                    }
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Parse driveFileId and fileName from taskDescription
        guard let description = downloadTask.taskDescription else { return }
        let parts = description.components(separatedBy: ":::")
        guard parts.count == 2 else { return }

        let driveFileId = parts[0]
        let fileName = parts[1]

        // Validate the HTTP response — Google Drive returns 401/403 JSON errors
        // that URLSession treats as successful downloads
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errorMsg: String
            switch httpResponse.statusCode {
            case 401: errorMsg = "Authentication expired. Please sign out and back in."
            case 403: errorMsg = "Download quota exceeded for this file. Try again in a few hours, or copy the file to your own Google Drive."
            case 404: errorMsg = "File not found on Google Drive."
            default:  errorMsg = "Download failed (HTTP \(httpResponse.statusCode))."
            }
            Task { @MainActor in
                self.activeDownloads[driveFileId]?.error = errorMsg
                self.tasks.removeValue(forKey: downloadTask.taskIdentifier)
                self.fileNames.removeValue(forKey: driveFileId)
                self.downloadCompleted.send((driveFileId, nil))
            }
            return
        }

        // Validate the downloaded file is actually audio (not a tiny JSON error response)
        // Audio files are always at least a few KB; API error responses are typically < 1KB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: location.path),
           let fileSize = attrs[.size] as? Int64, fileSize < 1024 {
            Task { @MainActor in
                self.activeDownloads[driveFileId]?.error = "Downloaded file is too small — likely an API error."
                self.tasks.removeValue(forKey: downloadTask.taskIdentifier)
                self.fileNames.removeValue(forKey: driveFileId)
                self.downloadCompleted.send((driveFileId, nil))
            }
            return
        }

        // Move file to permanent location (must happen synchronously before this method returns)
        let destination = Self.audiobooksDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)

        do {
            try FileManager.default.moveItem(at: location, to: destination)

            // Exclude from iCloud backup
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var destURL = destination
            try destURL.setResourceValues(resourceValues)

            Task { @MainActor in
                self.activeDownloads[driveFileId]?.isComplete = true
                self.tasks.removeValue(forKey: downloadTask.taskIdentifier)
                self.fileNames.removeValue(forKey: driveFileId)
                self.downloadCompleted.send((driveFileId, destination))
            }
        } catch {
            Task { @MainActor in
                self.activeDownloads[driveFileId]?.error = error.localizedDescription
                self.tasks.removeValue(forKey: downloadTask.taskIdentifier)
                self.fileNames.removeValue(forKey: driveFileId)
                self.downloadCompleted.send((driveFileId, nil))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = downloadTask.taskDescription else { return }
        let parts = description.components(separatedBy: ":::")
        guard let driveFileId = parts.first else { return }

        Task { @MainActor in
            guard var progress = self.activeDownloads[driveFileId] else { return }
            let previousFraction = progress.fraction
            progress.bytesDownloaded = totalBytesWritten
            progress.totalBytes = totalBytesExpectedToWrite
            // Every row observes this dictionary, so only publish when the ring would visibly move.
            guard progress.totalBytes <= 0 || abs(progress.fraction - previousFraction) >= 0.01 else { return }
            self.activeDownloads[driveFileId] = progress
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        guard let description = task.taskDescription else { return }
        let parts = description.components(separatedBy: ":::")
        guard let driveFileId = parts.first else { return }

        Task { @MainActor in
            self.activeDownloads[driveFileId]?.error = error.localizedDescription
            self.tasks.removeValue(forKey: task.taskIdentifier)
            self.fileNames.removeValue(forKey: driveFileId)
            self.downloadCompleted.send((driveFileId, nil))
        }
    }

    /// Called when all background events for the session have been delivered.
    /// Calls the system completion handler stored by AppDelegate.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            BackgroundSessionRegistry.shared.completionHandler?()
            BackgroundSessionRegistry.shared.completionHandler = nil
        }
    }
}
