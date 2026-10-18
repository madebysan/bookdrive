import Foundation

// Convenience accessors for the Core Data Bookmark entity
extension Bookmark {

    /// Display name — falls back to "Bookmark at <time>" if no name set
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return "Bookmark at \(formattedTimestamp)"
    }

    /// Formats the timestamp as a scrubber-style time string (h:mm:ss or m:ss)
    var formattedTimestamp: String {
        Book.formatScrubberTime(timestamp)
    }
}
