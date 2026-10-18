import CoreData

/// Reconciles a Drive listing with the books stored for one library.
///
/// Pure data work: no network, no UI state, no saving. `LibraryViewModel.performSync`
/// lists Drive, calls `reconcile`, saves, and then starts enrichment. Keeping the diff
/// here means it can be exercised in tests with fixture `DriveItem`s.
enum LibrarySync {

    struct Outcome: Equatable {
        /// Entries in the Drive listing, including duplicates
        let listed: Int
        let added: Int
        let removed: Int
    }

    /// Creates a `Book` for each new Drive file, updates size and subfolder for files
    /// already known, deletes books whose file is no longer listed, and fills in a
    /// parsed title and author for books that predate filename parsing.
    ///
    /// Scoped to `library`: books of other libraries are never touched. Downloaded
    /// files on disk are not removed here. Does not save `context`.
    @discardableResult
    static func reconcile(
        driveResults: [(file: DriveItem, subfolder: String?)],
        library: Library,
        context: NSManagedObjectContext
    ) -> Outcome {
        // Fetch existing books scoped to THIS library only
        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        let existingBooks = (try? context.fetch(request)) ?? []
        var booksByDriveId: [String: Book] = [:]
        for book in existingBooks {
            if let driveId = book.driveFileId {
                booksByDriveId[driveId] = book
            }
        }

        // Add new files, update existing
        var seenIds = Set<String>()
        var newBooks = 0
        for (file, subfolder) in driveResults {
            // Drive can list the same file twice when it has several parents
            guard !seenIds.contains(file.id) else { continue }
            seenIds.insert(file.id)

            if let existing = booksByDriveId[file.id] {
                // Update file size if it changed
                if let size = file.size, existing.fileSize != size {
                    existing.fileSize = size
                }
                // Update subfolder name (may change if file was moved)
                if existing.subfolderName != subfolder {
                    existing.subfolderName = subfolder
                }
            } else {
                // New book — create Core Data entity
                let book = Book(context: context)
                book.id = UUID()
                book.driveFileId = file.id
                book.filePath = file.name       // relative filename
                book.fileSize = file.size ?? 0
                book.fileModDate = file.modifiedTime
                book.isDownloaded = false
                book.addedDate = Date()
                book.subfolderName = subfolder
                book.library = library

                // Parse the filename right away so every book has a title and author
                // before any network work happens.
                let parsed = MetadataExtractor.parseFilename(file.name)
                book.title = parsed.title
                book.author = parsed.author
                book.metadataLoaded = true
                newBooks += 1
            }
        }

        // Remove books that no longer exist in Drive (but keep downloaded files)
        var removed = 0
        for book in existingBooks {
            if let driveId = book.driveFileId, !seenIds.contains(driveId) {
                context.delete(book)
                removed += 1
            }
        }

        // Older books that never went through filename parsing
        for book in existingBooks where !book.metadataLoaded {
            if let name = book.filePath {
                let parsed = MetadataExtractor.parseFilename(name)
                if book.title == nil { book.title = parsed.title }
                if book.author == nil { book.author = parsed.author }
            }
            book.metadataLoaded = true
        }

        return Outcome(listed: driveResults.count, added: newBooks, removed: removed)
    }
}
