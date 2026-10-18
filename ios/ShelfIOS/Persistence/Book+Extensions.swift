import Foundation
import UIKit
import CoreData

// Convenience accessors for the Core Data Book entity
extension Book {

    // MARK: - Media Type

    /// Video file extensions recognized by Shelf
    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm"]

    /// True if the file is a video based on its extension
    var isVideo: Bool {
        guard let path = filePath,
              let ext = path.split(separator: ".").last?.lowercased() else { return false }
        return Self.videoExtensions.contains(ext)
    }

    // MARK: - Cover Art

    /// Full-size cover (decoded once and cached), or the appropriate placeholder.
    /// Use for the player and grid cards; rows should use `thumbnailImage`.
    var coverImage: UIImage {
        CoverImageCache.shared.image(for: self, size: .full) ?? placeholderImage
    }

    /// Small cover for list rows, the mini player, and collages.
    var thumbnailImage: UIImage {
        CoverImageCache.shared.image(for: self, size: .thumbnail) ?? placeholderImage
    }

    private var placeholderImage: UIImage {
        isVideo ? Self.videoPlaceholderCover : Self.placeholderCover
    }

    /// Cached placeholder image — drawn once, reused for all books without cover art
    private static let _cachedPlaceholder: UIImage = {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Background
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()

            // Book icon using SF Symbol
            let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .light)
            if let symbol = UIImage(systemName: "book.closed.fill", withConfiguration: config) {
                let symbolSize = symbol.size
                let x = (size.width - symbolSize.width) / 2
                let y = (size.height - symbolSize.height) / 2
                UIColor.tertiaryLabel.setFill()
                symbol.draw(in: CGRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
            }
        }
    }()

    /// A simple programmatic placeholder for books without cover art (1:1)
    static var placeholderCover: UIImage { _cachedPlaceholder }

    /// Cached video placeholder image — uses a film icon instead of a book icon
    private static let _cachedVideoPlaceholder: UIImage = {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Background
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()

            // Film icon using SF Symbol
            let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .light)
            if let symbol = UIImage(systemName: "film", withConfiguration: config) {
                let symbolSize = symbol.size
                let x = (size.width - symbolSize.width) / 2
                let y = (size.height - symbolSize.height) / 2
                UIColor.tertiaryLabel.setFill()
                symbol.draw(in: CGRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
            }
        }
    }()

    /// Placeholder for video items without cover art
    static var videoPlaceholderCover: UIImage { _cachedVideoPlaceholder }

    // MARK: - Computed Properties

    /// Progress as a value between 0 and 1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(playbackPosition / duration, 1.0)
    }

    /// True if the book has any listening progress but isn't marked completed
    var isInProgress: Bool {
        playbackPosition > 0 && !isCompleted
    }

    /// Formatted duration string (e.g., "12h 34m")
    var formattedDuration: String {
        Self.formatTime(duration)
    }

    /// Display title (falls back to filename if no metadata title)
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        // On iOS, filePath stores a relative filename (not a full path)
        let name = filePath ?? "Untitled"
        if let dot = name.lastIndex(of: ".") {
            return String(name[name.startIndex..<dot])
        }
        return name
    }

    /// Display author (falls back to "Unknown Author")
    var displayAuthor: String {
        if let a = author, !a.isEmpty { return a }
        return "Unknown Author"
    }

    /// Display genre (falls back to "Uncategorized")
    var displayGenre: String {
        if let g = genre, !g.isEmpty { return g }
        return "Uncategorized"
    }

    /// Display subfolder name (nil if the book is in the root folder)
    var displaySubfolder: String? {
        guard let name = subfolderName, !name.isEmpty else { return nil }
        return name
    }

    /// Formatted file size string (e.g., "128 MB")
    var formattedFileSize: String {
        guard fileSize > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    /// The local file URL where this book is stored after download
    var localFileURL: URL? {
        guard let name = filePath else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Audiobooks").appendingPathComponent(name)
    }

    /// True if playback would stream from Drive (not downloaded locally)
    var willStream: Bool {
        if isDownloaded, let localURL = localFileURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Formats seconds into a readable time string
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Formats seconds into a scrubber-style time string (h:mm:ss or m:ss)
    static func formatScrubberTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
