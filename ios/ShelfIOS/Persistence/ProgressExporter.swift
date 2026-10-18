import Foundation
import CoreData

/// Handles exporting and importing audiobook progress data as JSON
struct ProgressExporter {

    // MARK: - Codable Models

    struct ExportData: Codable {
        let exportDate: Date
        let version: String
        let books: [BookProgress]
    }

    struct BookProgress: Codable {
        let filePath: String
        let playbackPosition: Double
        let lastPlayedDate: Date?
        let isCompleted: Bool
        let bookmarks: [BookmarkData]
    }

    struct BookmarkData: Codable {
        let timestamp: Double
        let name: String
        let note: String?
        let createdDate: Date
    }

    struct ImportResult {
        let booksUpdated: Int
        let bookmarksCreated: Int
        let booksNotFound: Int
    }

    // MARK: - Export

    /// Exports all book progress and bookmarks to JSON data
    static func exportProgress(books: [Book]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let bookEntries: [BookProgress] = books.map { book in
            let bookmarkSet = book.bookmarks as? Set<Bookmark> ?? []
            let bookmarkEntries: [BookmarkData] = bookmarkSet
                .sorted { $0.timestamp < $1.timestamp }
                .map { bm in
                    BookmarkData(
                        timestamp: bm.timestamp,
                        name: bm.name ?? "Bookmark",
                        note: bm.note,
                        createdDate: bm.createdDate ?? Date()
                    )
                }

            return BookProgress(
                filePath: book.filePath ?? "",
                playbackPosition: book.playbackPosition,
                lastPlayedDate: book.lastPlayedDate,
                isCompleted: book.isCompleted,
                bookmarks: bookmarkEntries
            )
        }

        let exportData = ExportData(
            exportDate: Date(),
            version: "1.0",
            books: bookEntries
        )

        return try? encoder.encode(exportData)
    }

    // MARK: - Import

    /// Imports progress data from JSON, matching books by filePath
    static func importProgress(from data: Data, context: NSManagedObjectContext) -> ImportResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let importData = try? decoder.decode(ExportData.self, from: data) else {
            return nil
        }

        let request: NSFetchRequest<Book> = Book.fetchRequest()
        guard let existingBooks = try? context.fetch(request) else { return nil }

        var booksByPath: [String: Book] = [:]
        for book in existingBooks {
            if let path = book.filePath {
                booksByPath[path] = book
            }
        }

        var booksUpdated = 0
        var bookmarksCreated = 0
        var booksNotFound = 0

        for entry in importData.books {
            guard let book = booksByPath[entry.filePath] else {
                booksNotFound += 1
                continue
            }

            book.playbackPosition = entry.playbackPosition
            book.lastPlayedDate = entry.lastPlayedDate
            book.isCompleted = entry.isCompleted
            booksUpdated += 1

            let existingBookmarks = (book.bookmarks as? Set<Bookmark>) ?? []
            let existingTimestamps = Set(existingBookmarks.map { $0.timestamp })

            for bmEntry in entry.bookmarks {
                if !existingTimestamps.contains(bmEntry.timestamp) {
                    let bookmark = Bookmark(context: context)
                    bookmark.id = UUID()
                    bookmark.timestamp = bmEntry.timestamp
                    bookmark.name = bmEntry.name
                    bookmark.note = bmEntry.note
                    bookmark.createdDate = bmEntry.createdDate
                    bookmark.book = book
                    bookmarksCreated += 1
                }
            }
        }

        if context.hasChanges {
            try? context.save()
        }

        return ImportResult(
            booksUpdated: booksUpdated,
            bookmarksCreated: bookmarksCreated,
            booksNotFound: booksNotFound
        )
    }
}
