import Foundation
import CoreData
import Combine
import UIKit

/// Manages the audiobook library — syncs Drive file list with Core Data,
/// handles downloads, metadata extraction, and library filtering.
@MainActor
class LibraryViewModel: ObservableObject {

    @Published var books: [Book] = []
    @Published var isLoading: Bool = false
    @Published var isFetchingMetadata: Bool = false
    @Published var isLookingUpCovers: Bool = false
    @Published var coverLookupProgress: Int = 0
    @Published var coverLookupTotal: Int = 0
    @Published var error: String?
    @Published var searchText: String = ""

    enum SortOrder: String, CaseIterable {
        case title = "Title"
        case recent = "Recently Played"
        case author = "Author"
        case rating = "Rating"
        case subfolder = "Subfolder"
        case shortest = "Shortest First"
        case longest = "Longest First"
        case largestFile = "Largest File"
        case smallestFile = "Smallest File"
    }
    @Published var sortOrder: SortOrder = .title

    /// Filter chips for library organization
    enum LibraryFilter: String, CaseIterable {
        case all = "All"
        case inProgress = "In Progress"
        case completed = "Completed"
        case recentlyAdded = "Recently Added"
        case notStarted = "Not Started"
        case quickListens = "Under 6 Hours"
        case starred = "Starred"
        case downloaded = "Downloaded"
        case hidden = "Hidden"
    }

    /// Filters that should appear in the chip bar (hidden only shows when there are hidden books)
    var visibleFilters: [LibraryFilter] {
        var filters: [LibraryFilter] = [.all, .inProgress]
        // Show Starred right after In Progress, but only when there are starred books
        if books.contains(where: { $0.isStarred }) {
            filters.append(.starred)
        }
        filters.append(contentsOf: [.completed, .recentlyAdded, .notStarted])
        // Show "Under 6 Hours" only when the library has qualifying books
        if books.contains(where: { $0.duration > 0 && $0.duration < 6 * 3600 }) {
            filters.append(.quickListens)
        }
        // Show Downloaded only when there are downloaded books
        if books.contains(where: { $0.isDownloaded }) {
            filters.append(.downloaded)
        }
        if books.contains(where: { $0.isHidden }) {
            filters.append(.hidden)
        }
        return filters
    }
    @Published var filter: LibraryFilter = .all
    @Published var selectedGenre: String? = nil

    /// Filtered and sorted books for display. Stored, not computed: the list reads it
    /// several times per render, and recomputing (a full sort with localized string
    /// comparison) on every render was a major cause of scroll jank.
    @Published private(set) var displayBooks: [Book] = []

    /// Available genres with book counts, sorted by count descending, then by name,
    /// so genres with equal counts keep one order between launches
    var availableGenres: [(name: String, count: Int)] {
        var genreCounts: [String: Int] = [:]
        for book in books where !book.isHidden {
            genreCounts[book.displayGenre, default: 0] += 1
        }
        return genreCounts.map { (name: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Returns up to `limit` cover images for books in the given genre.
    /// Prioritizes books that have real cover art over placeholders.
    func coversForGenre(_ genre: String, limit: Int = 4) -> [UIImage] {
        let genreBooks = books.filter { !$0.isHidden && $0.displayGenre == genre }
        // Prioritize books with actual cover art
        let withCovers = genreBooks.filter { $0.coverArtData != nil }
        let withoutCovers = genreBooks.filter { $0.coverArtData == nil }
        let ordered = withCovers + withoutCovers
        return Array(ordered.prefix(limit)).map { $0.thumbnailImage }
    }

    let driveService: GoogleDriveService
    let downloadManager: DownloadManager
    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()

    /// The library whose books are currently loaded
    private(set) var currentLibrary: Library?

    /// In-flight Drive sync, so concurrent callers wait instead of starting a second one
    private var syncTask: Task<Void, Never>?
    private var syncingLibraryID: NSManagedObjectID?

    /// Background enrichment (covers, duration, chapters). One instance at a time.
    private var enrichmentTask: Task<Void, Never>?
    private var enrichmentPending = false
    /// Incremented per enrichment run so a cancelled run cannot clear its replacement
    private var enrichmentGeneration = 0

    /// Pending AVFoundation reads (duration, tags, embedded cover), front = next.
    /// Rows move their book to the front as they come on screen.
    private var metadataQueue = WorkQueue<NSManagedObjectID>()
    /// Pending title-search cover lookups for books whose file carried no art
    private var coverQueue = WorkQueue<NSManagedObjectID>()

    /// Progress of the current AVFoundation pass, for the toolbar
    @Published private(set) var metadataProgress: Int = 0
    @Published private(set) var metadataTotal: Int = 0

    /// Fires when Core Data reports a change to any Book, so `displayBooks` can be rebuilt
    private let bookChanges = PassthroughSubject<Void, Never>()

    init(driveService: GoogleDriveService, downloadManager: DownloadManager) {
        self.driveService = driveService
        self.downloadManager = downloadManager
        self.context = PersistenceController.shared.container.viewContext

        // Subscribe to background download completions
        downloadManager.downloadCompleted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (driveFileId, localURL) in
                self?.handleDownloadCompleted(driveFileId: driveFileId, localURL: localURL)
            }
            .store(in: &cancellables)

        // Rebuild displayBooks when its inputs change. `receive(on:)` defers the sink to
        // the next main-queue turn so the @Published properties hold their new values.
        let inputs = Publishers.CombineLatest4($books, $filter, $selectedGenre, $sortOrder)
            .map { _ in () }
        let search = $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .map { _ in () }
        let changes = bookChanges
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
        Publishers.Merge3(inputs, search, changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeDisplayBooks() }
            .store(in: &cancellables)

        // Any Book edit (row actions, metadata, playback position, CloudKit merges)
        // may change what is shown or in which order.
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
            .sink { [weak self] note in
                let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey]
                let touchedBook = keys.contains { key in
                    (note.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is Book } ?? false
                }
                if touchedBook { self?.bookChanges.send() }
            }
            .store(in: &cancellables)
    }

    private func recomputeDisplayBooks() {
        let result = Self.filterAndSort(
            books, filter: filter, genre: selectedGenre, searchText: searchText, sortOrder: sortOrder
        )
        // Skip the publish (and the list redraw) when membership and order are unchanged;
        // rows observe their own Book for content changes.
        if result.map(\.objectID) != displayBooks.map(\.objectID) {
            displayBooks = result
        }
    }

    // MARK: - Download State (forwarded so rows need not observe DownloadManager)

    func isDownloading(_ book: Book) -> Bool {
        guard let driveId = book.driveFileId else { return false }
        return downloadManager.isDownloading(driveId)
    }

    func cancelDownload(for book: Book) {
        guard let driveId = book.driveFileId else { return }
        downloadManager.cancel(driveFileId: driveId)
    }

    /// Pure filter + sort used to build `displayBooks`.
    static func filterAndSort(
        _ books: [Book],
        filter: LibraryFilter,
        genre selectedGenre: String?,
        searchText: String,
        sortOrder: SortOrder
    ) -> [Book] {
        var result = books

        // Filter by genre if one is selected
        if let genre = selectedGenre {
            result = result.filter { $0.displayGenre == genre }
        }

        // Apply library filter
        switch filter {
        case .all:
            // Hide hidden books from the main view
            result = result.filter { !$0.isHidden }
        case .inProgress:
            result = result.filter { !$0.isHidden && $0.isInProgress }
        case .completed:
            result = result.filter { !$0.isHidden && $0.isCompleted }
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            result = result.filter { !$0.isHidden && ($0.addedDate ?? .distantPast) > cutoff }
        case .notStarted:
            result = result.filter { !$0.isHidden && $0.playbackPosition == 0 && !$0.isCompleted }
        case .quickListens:
            result = result.filter { !$0.isHidden && $0.duration > 0 && $0.duration < 6 * 3600 }
        case .starred:
            result = result.filter { !$0.isHidden && $0.isStarred }
        case .downloaded:
            result = result.filter { !$0.isHidden && $0.isDownloaded }
        case .hidden:
            result = result.filter { $0.isHidden }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.displayTitle.lowercased().contains(query) ||
                $0.displayAuthor.lowercased().contains(query)
            }
        }

        // Sort
        switch sortOrder {
        case .title:
            result.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .recent:
            result.sort { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
        case .author:
            result.sort { $0.displayAuthor.localizedCaseInsensitiveCompare($1.displayAuthor) == .orderedAscending }
        case .rating:
            result.sort {
                // Highest rating first, unrated (0) go last, ties sorted by title
                if $0.rating == $1.rating {
                    return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
                }
                if $0.rating == 0 { return false }
                if $1.rating == 0 { return true }
                return $0.rating > $1.rating
            }
        case .subfolder:
            result.sort {
                let a = $0.displaySubfolder ?? ""
                let b = $1.displaySubfolder ?? ""
                if a == b {
                    return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
                }
                if a.isEmpty { return false }
                if b.isEmpty { return true }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .shortest:
            result.sort {
                // Books with no duration go last
                if $0.duration == 0 && $1.duration == 0 { return false }
                if $0.duration == 0 { return false }
                if $1.duration == 0 { return true }
                return $0.duration < $1.duration
            }
        case .longest:
            result.sort {
                if $0.duration == 0 && $1.duration == 0 { return false }
                if $0.duration == 0 { return false }
                if $1.duration == 0 { return true }
                return $0.duration > $1.duration
            }
        case .largestFile:
            result.sort {
                if $0.fileSize == 0 && $1.fileSize == 0 { return false }
                if $0.fileSize == 0 { return false }
                if $1.fileSize == 0 { return true }
                return $0.fileSize > $1.fileSize
            }
        case .smallestFile:
            result.sort {
                if $0.fileSize == 0 && $1.fileSize == 0 { return false }
                if $0.fileSize == 0 { return false }
                if $1.fileSize == 0 { return true }
                return $0.fileSize < $1.fileSize
            }
        }

        return result
    }

    /// Syncs the Drive folder contents with the local Core Data library.
    /// Creates Book entities for new files, removes ones that no longer exist in Drive.
    /// Finishes in seconds; covers, duration, and chapters are filled in afterwards by
    /// `startEnrichment()` so the loading state reflects only the Drive sync.
    ///
    /// Concurrent calls are coalesced: a call for a folder that is already syncing waits
    /// for that sync instead of starting a second one, which used to insert duplicate books.
    func syncLibrary(_ library: Library) async {
        while let running = syncTask {
            let sameLibrary = (syncingLibraryID == library.objectID)
            await running.value
            if sameLibrary { return }
        }

        let task = Task { await performSync(library) }
        syncTask = task
        syncingLibraryID = library.objectID
        await task.value
        if syncTask == task {
            syncTask = nil
            syncingLibraryID = nil
        }
    }

    private func performSync(_ library: Library) async {
        guard let folderId = library.folderPath, !folderId.isEmpty else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            guard let credential = await driveService.credential(for: library) else {
                throw DriveError.notAuthenticated
            }

            // Use recursive listing to include subfolders
            let started = Date()
            let driveResults = try await driveService.listMediaFilesRecursive(in: folderId, credential: credential)
            let listingSeconds = Date().timeIntervalSince(started)

            let outcome = LibrarySync.reconcile(driveResults: driveResults, library: library, context: context)
            PersistenceController.shared.save()
            print("[Shelf] Sync: \(outcome.listed) files in Drive, \(outcome.added) new, \(outcome.removed) removed, listed in \(String(format: "%.1f", listingSeconds))s")

            // The user may have switched libraries while Drive was being listed.
            // Only show and enrich this library if it is still the active one.
            guard currentLibrary == nil || currentLibrary?.objectID == library.objectID else { return }
            loadBooks(for: library)
            startEnrichment()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Enrichment (covers, duration, chapters)

    /// Runs the slow metadata passes in the background. First every unread file is
    /// opened once from Drive for its duration, tags, and embedded cover, several at a
    /// time; then the title-search APIs fill covers only for files that carried none.
    /// Only one instance runs at a time; a request made while one is running queues a
    /// single follow-up pass for newly added books.
    func startEnrichment() {
        enrichmentPending = true
        guard enrichmentTask == nil else { return }

        enrichmentGeneration += 1
        let generation = enrichmentGeneration
        enrichmentTask = Task { @MainActor [weak self] in
            while true {
                guard let self, self.enrichmentPending, !Task.isCancelled else { break }
                self.enrichmentPending = false
                await self.fetchRemoteMetadata()
                guard !Task.isCancelled else { break }
                await self.lookUpMissingCovers()
            }
            if let self, self.enrichmentGeneration == generation {
                self.enrichmentTask = nil
            }
        }
    }

    /// Stops the background passes, for example when switching libraries.
    func cancelEnrichment() {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        enrichmentPending = false
        metadataQueue.removeAll()
        coverQueue.removeAll()
        isLookingUpCovers = false
        isFetchingMetadata = false
    }

    /// Called by rows as they appear: read this book's file (or look up its cover)
    /// before the rest of the queue. No effect once the book's work is done.
    func prioritizeEnrichment(for book: Book) {
        metadataQueue.prioritize(book.objectID)
        coverQueue.prioritize(book.objectID)
    }

    /// Resolves a queued key back to a live book, skipping deleted ones
    private func book(for id: NSManagedObjectID) -> Book? {
        guard let book = try? context.existingObject(with: id) as? Book, !book.isDeleted else { return nil }
        return book
    }

    /// Loads books from Core Data, scoped to a specific library
    func loadBooks(for library: Library) {
        if let current = currentLibrary, current.objectID != library.objectID {
            cancelEnrichment()
        }
        currentLibrary = library
        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Book.title, ascending: true)]
        books = (try? context.fetch(request)) ?? []
    }

    /// Downloads a book from Drive, extracts metadata after download
    func downloadBook(_ book: Book) {
        guard let driveId = book.driveFileId, let fileName = book.filePath else { return }
        Task {
            guard let credential = await driveService.credential(for: book.library) else { return }
            downloadManager.download(driveFileId: driveId, fileName: fileName, credential: credential)
        }
    }

    /// Downloads all non-downloaded, non-hidden books
    func downloadAll() {
        let eligible = books.filter { !$0.isDownloaded && !$0.isHidden }
        downloadManager.queuedCount = eligible.count
        for book in eligible {
            downloadBook(book)
        }
    }

    /// Downloads all non-downloaded books in the current filtered view
    func downloadFiltered() {
        let eligible = displayBooks.filter { !$0.isDownloaded }
        downloadManager.queuedCount = eligible.count
        for book in eligible {
            downloadBook(book)
        }
    }

    /// Count of non-downloaded books (for confirmation dialogs)
    var nonDownloadedCount: Int {
        books.filter { !$0.isDownloaded && !$0.isHidden }.count
    }

    /// Count of non-downloaded books in current filtered view
    var nonDownloadedFilteredCount: Int {
        displayBooks.filter { !$0.isDownloaded }.count
    }

    /// Deletes the local file for a book but keeps metadata intact
    func deleteDownload(for book: Book) {
        if let fileName = book.filePath {
            DownloadManager.deleteLocalFile(fileName: fileName)
        }
        book.isDownloaded = false
        // Keep metadata (title, author, cover, duration) — it was fetched remotely
        PersistenceController.shared.save()
        objectWillChange.send()
    }

    /// Clears all cached metadata (covers, titles, authors, etc.) from Core Data.
    /// Books revert to showing filenames until the next sync re-fetches metadata.
    /// Returns the approximate bytes freed (mostly cover art).
    func clearMetadataCache() -> Int64 {
        var bytesFreed: Int64 = 0
        for book in books {
            if let coverData = book.coverArtData {
                bytesFreed += Int64(coverData.count)
            }
            book.coverArtData = nil
            book.coverFromAPI = false
            book.title = nil
            book.author = nil
            book.genre = nil
            book.year = 0
            book.rating = 0
            book.duration = 0
            book.hasChapters = false
            book.metadataLoaded = false
            book.metadataFetchDate = nil
            book.coverLookupAttempted = false
        }
        PersistenceController.shared.save()
        objectWillChange.send()
        return bytesFreed
    }

    // MARK: - Import / Export

    /// Exports all book progress and bookmarks to JSON data
    func exportProgressData() -> Data? {
        ProgressExporter.exportProgress(books: books)
    }

    /// Imports progress from JSON data, returns a summary string
    func importProgress(from data: Data) -> String? {
        let context = PersistenceController.shared.container.viewContext
        guard let result = ProgressExporter.importProgress(from: data, context: context) else {
            return nil
        }

        objectWillChange.send()

        var summary = "Updated \(result.booksUpdated) book(s)."
        if result.bookmarksCreated > 0 {
            summary += "\nImported \(result.bookmarksCreated) bookmark(s)."
        }
        if result.booksNotFound > 0 {
            summary += "\nSkipped \(result.booksNotFound) book(s) not in library."
        }
        return summary
    }

    // MARK: - Remote Metadata

    /// Forces a full re-fetch of metadata (cover art, title, author, etc.) for all
    /// books in the current library — even ones that already have metadata.
    func refreshAllMetadata() async {
        for book in books {
            book.metadataLoaded = false
            book.coverLookupAttempted = false
            book.coverArtData = nil
            book.duration = 0
        }
        PersistenceController.shared.save()

        // Same pipeline as syncWithDrive: filenames → API covers → AVFoundation
        let booksNeedingTitles = books.filter { !$0.metadataLoaded }
        for book in booksNeedingTitles {
            if let name = book.filePath {
                let parsed = MetadataExtractor.parseFilename(name)
                if book.title == nil { book.title = parsed.title }
                if book.author == nil { book.author = parsed.author }
            }
            book.metadataLoaded = true
        }
        PersistenceController.shared.save()
        CoverImageCache.shared.removeAll()

        cancelEnrichment()
        startEnrichment()
    }

    /// Refreshes metadata for a single book by re-fetching from Drive.
    /// Uses a longer timeout than bulk sync since only one file is being fetched.
    func fetchMetadataForBook(_ book: Book) async {
        guard let driveId = book.driveFileId else { return }
        guard let credential = await driveService.credential(for: book.library) else { return }

        // Clear existing cover so AVFoundation doesn't use a stale cache
        book.coverArtData = nil
        book.metadataLoaded = false
        book.coverLookupAttempted = false
        PersistenceController.shared.save()
        objectWillChange.send()

        // Longer timeout for single-book refresh (no concurrency pressure)
        guard let metadata = await MetadataExtractor.extractRemoteWithTimeout(
            driveFileId: driveId, credential: credential, timeout: 45
        ) else {
            // Timed out — mark as loaded so it doesn't show as "fetching" forever
            book.metadataLoaded = true
            PersistenceController.shared.save()
            objectWillChange.send()
            return
        }

        applyMetadata(metadata, to: book, fileName: book.filePath)
        PersistenceController.shared.save()
        objectWillChange.send()

        // If no embedded cover was found, try the API waterfall
        if book.coverArtData == nil, let title = book.title {
            print("Cover lookup: trying API for \"\(title)\"")
            if let coverData = await CoverArtService.fetchCover(title: title, author: book.author) {
                book.coverArtData = coverData
                book.coverFromAPI = true
                print("Found cover for \"\(title)\"")
            }
            book.coverLookupAttempted = true
            PersistenceController.shared.save()
            objectWillChange.send()
        }
    }

    /// Reads every unread file from Drive via AVFoundation: duration, genre, year,
    /// chapters, and the embedded cover in one pass. This is the slow background work;
    /// books whose rows are on screen are read first.
    private func fetchRemoteMetadata() async {
        // Snapshot: `books` can be swapped for another library while this runs
        let libraryBooks = books
        let booksNeedingMetadata = libraryBooks.filter { $0.duration == 0 && $0.driveFileId != nil }
        guard !booksNeedingMetadata.isEmpty else {
            print("[Shelf] All books already have full metadata")
            return
        }

        guard let credential = await driveService.credential(for: currentLibrary) else { return }

        isFetchingMetadata = true
        metadataProgress = 0
        metadataTotal = booksNeedingMetadata.count
        defer {
            isFetchingMetadata = false
            metadataQueue.removeAll()
        }
        let total = booksNeedingMetadata.count
        print("[Shelf] Starting metadata fetch for \(total) books")

        // Pass 1: 15s timeout — enough for well-structured files, fast failure for huge ones
        metadataQueue.enqueue(contentsOf: booksNeedingMetadata.map(\.objectID))
        let pass1 = await runMetadataWorkers(credential: credential, timeout: 15)
        print("[Shelf] Pass 1 complete: \(pass1.success) succeeded, \(pass1.fail) failed out of \(total)")

        // Pass 2: Quick retry for failed books — fresh token, slightly longer timeout.
        // Only retry a few; large files that timed out at 15s won't succeed at 20s either.
        guard !Task.isCancelled else { return }
        let stillNeedDuration = booksNeedingMetadata.filter { $0.duration == 0 && !$0.isDeleted }
        if !stillNeedDuration.isEmpty && stillNeedDuration.count <= 10 {
            print("[Shelf] Retrying \(stillNeedDuration.count) failed books...")
            try? await Task.sleep(for: .seconds(2))

            if let retryCredential = await driveService.credential(for: currentLibrary) {
                metadataQueue.enqueue(contentsOf: stillNeedDuration.map(\.objectID))
                let pass2 = await runMetadataWorkers(credential: retryCredential, timeout: 20)
                print("[Shelf] Pass 2 complete: \(pass2.success) succeeded, \(pass2.fail) still failed")
            }
        } else if !stillNeedDuration.isEmpty {
            print("[Shelf] Skipping retry — \(stillNeedDuration.count) books failed (too many to retry)")
        }

        let finalNoDuration = booksNeedingMetadata.filter { $0.duration == 0 && !$0.isDeleted }.count
        print("[Shelf] Metadata fetch done. \(total - finalNoDuration)/\(total) got full metadata, \(finalNoDuration) still missing duration")
    }

    /// Drains `metadataQueue` with a few concurrent AVFoundation reads. Each read also
    /// pulls the embedded cover, which is why there is no separate cover pass for
    /// files that carry art. Refreshes the OAuth token every 50 books, saves every 10.
    private func runMetadataWorkers(
        credential: DriveCredential,
        timeout: TimeInterval,
        concurrency: Int = 3
    ) async -> (success: Int, fail: Int) {
        var successCount = 0
        var failCount = 0
        var unsaved = 0
        var currentCredential = credential
        var booksSinceRefresh = 0
        let library = currentLibrary

        await withTaskGroup(of: Bool.self) { group in
            var active = 0
            while !Task.isCancelled {
                // Keep `concurrency` reads in flight, always taking the front of the
                // queue so prioritized (visible) books go next.
                while active < concurrency, let id = metadataQueue.popFirst() {
                    guard let book = book(for: id), let driveId = book.driveFileId else { continue }

                    booksSinceRefresh += 1
                    if booksSinceRefresh >= 50 {
                        if let refreshed = await driveService.credential(for: library) {
                            currentCredential = refreshed
                        }
                        booksSinceRefresh = 0
                    }

                    let credentialForTask = currentCredential
                    let fileName = book.filePath
                    active += 1
                    group.addTask { [weak self] in
                        guard let self else { return false }
                        guard let metadata = await MetadataExtractor.extractRemoteWithTimeout(
                            driveFileId: driveId, credential: credentialForTask, timeout: timeout, skipCoverArt: false
                        ) else {
                            print("[Shelf] Metadata timeout: \(fileName ?? driveId)")
                            return false
                        }

                        await MainActor.run {
                            self.applyMetadata(metadata, to: book, fileName: fileName)
                        }
                        return true
                    }
                }

                guard active > 0, let result = await group.next() else { break }
                active -= 1
                if result { successCount += 1 } else { failCount += 1 }
                metadataProgress += 1
                unsaved += 1
                if unsaved >= 10 {
                    PersistenceController.shared.save()
                    unsaved = 0
                }
            }

            // Drain anything still running after a cancel
            for await result in group {
                if result { successCount += 1 } else { failCount += 1 }
            }
        }

        // Final save for any remaining unsaved books
        PersistenceController.shared.save()

        return (successCount, failCount)
    }

    /// Applies extracted metadata to a book, with filename parsing as a fallback
    /// for missing title/author.
    private func applyMetadata(_ metadata: AudiobookMetadata, to book: Book, fileName: String?) {
        var title = metadata.title
        var author = metadata.author

        // Filename fallback for missing title/author
        if (title == nil || author == nil), let name = fileName {
            let parsed = MetadataExtractor.parseFilename(name)
            if title == nil { title = parsed.title }
            if author == nil { author = parsed.author }
        }

        if let title = title { book.title = title }
        if let author = author { book.author = author }
        if let genre = metadata.genre { book.genre = genre }
        if metadata.year > 0 { book.year = metadata.year }
        if metadata.duration > 0 { book.duration = metadata.duration }
        if let coverData = metadata.coverArtData {
            // Embedded art can be several megabytes; keep a bounded JPEG so Core Data,
            // CloudKit, and the thumbnail cache stay light.
            book.coverArtData = Self.boundedCoverData(coverData)
        }
        book.hasChapters = metadata.hasChapters
        if metadata.rating > 0 { book.rating = metadata.rating }
        book.metadataLoaded = true
        book.metadataFetchDate = Date()
    }

    /// Re-encodes cover data to at most 600 px on its longest side. Falls back to the
    /// original bytes if they cannot be decoded.
    static func boundedCoverData(_ data: Data, maxPixelSize: Int = 600) -> Data {
        guard data.count > 200 * 1024,
              let image = CoverImageCache.decode(data, maxPixelSize: maxPixelSize),
              let jpeg = image.jpegData(compressionQuality: 0.85),
              jpeg.count < data.count else {
            return data
        }
        return jpeg
    }

    /// Called when a background download completes — marks book as downloaded and extracts metadata
    private func handleDownloadCompleted(driveFileId: String, localURL: URL?) {
        // Clean up the download progress entry regardless of success/failure
        // (keep it briefly so the UI can show the error, then remove)
        if localURL == nil {
            let errorMsg = downloadManager.activeDownloads[driveFileId]?.error
            if let errorMsg {
                // Surface as a playback error briefly — this is the simplest path for now
                print("Download failed for \(driveFileId): \(errorMsg)")
            }
            downloadManager.activeDownloads.removeValue(forKey: driveFileId)
            objectWillChange.send()
            return
        }

        downloadManager.activeDownloads.removeValue(forKey: driveFileId)
        guard let localURL = localURL else { return }

        // Find the book by drive ID
        guard let book = books.first(where: { $0.driveFileId == driveFileId }) else { return }

        book.isDownloaded = true
        PersistenceController.shared.save()

        // Extract metadata from the local file (more reliable than remote for some formats)
        Task {
            if let metadata = await MetadataExtractor.extractWithTimeout(from: localURL) {
                applyMetadata(metadata, to: book, fileName: book.filePath)
                PersistenceController.shared.save()
            }

            self.objectWillChange.send()
        }
    }

    // MARK: - Cover Art Management

    /// Clears the cover art for a single book and prevents re-fetching from API.
    func clearCover(for book: Book) {
        book.coverArtData = nil
        book.coverFromAPI = false
        book.coverLookupAttempted = true  // Don't re-fetch from API
        PersistenceController.shared.save()
        objectWillChange.send()
    }

    /// Clears all generated covers (API-fetched and video thumbnails), keeping
    /// embedded cover art from audio metadata. Cleared books show a placeholder
    /// until the next sync regenerates covers.
    /// Returns the number of covers cleared.
    @discardableResult
    func clearAllAPICovers() -> Int {
        var cleared = 0
        for book in books {
            if book.isVideo {
                // Video covers are always generated (thumbnail or API) — clear and
                // reset duration so fetchRemoteMetadata re-extracts on next sync
                if book.coverArtData != nil { cleared += 1 }
                book.coverArtData = nil
                book.coverFromAPI = false
                book.duration = 0
            } else if book.coverFromAPI {
                // Audio: only clear API-fetched covers, keep embedded metadata art
                book.coverArtData = nil
                book.coverFromAPI = false
                book.coverLookupAttempted = false
                cleared += 1
            }
        }
        PersistenceController.shared.save()
        // Force Core Data to re-fire KVO for each book so @ObservedObject picks up
        // the coverArtData change (external binary storage doesn't always notify)
        for book in books {
            context.refresh(book, mergeChanges: true)
        }
        objectWillChange.send()
        return cleared
    }

    // MARK: - Cover Art Lookup

    /// Searches free APIs (iTunes, Google Books, Open Library) for cover art on books
    /// whose file carried no embedded art. Runs after the AVFoundation pass, one book
    /// every 3 seconds because of the iTunes rate limit, visible rows first.
    func lookUpMissingCovers() async {
        // Find books that need cover lookup: have metadata + title, but no cover and haven't been tried
        let candidates = books.filter {
            $0.metadataLoaded &&
            $0.coverArtData == nil &&
            !$0.coverLookupAttempted &&
            $0.title != nil
        }

        guard !candidates.isEmpty else {
            let total = books.count
            let noMeta = books.filter { !$0.metadataLoaded }.count
            let noCover = books.filter { $0.coverArtData == nil }.count
            let alreadyTried = books.filter { $0.coverLookupAttempted }.count
            let noTitle = books.filter { $0.title == nil }.count
            print("Cover lookup: 0 candidates. total=\(total), noMetadata=\(noMeta), noCover=\(noCover), alreadyTried=\(alreadyTried), noTitle=\(noTitle)")
            return
        }

        isLookingUpCovers = true
        coverLookupProgress = 0
        coverLookupTotal = candidates.count
        defer {
            isLookingUpCovers = false
            coverQueue.removeAll()
        }

        print("Cover lookup: \(candidates.count) books to search")

        coverQueue.enqueue(contentsOf: candidates.map(\.objectID))
        var unsaved = 0
        while !Task.isCancelled, let id = coverQueue.popFirst() {
            guard let book = book(for: id), let title = book.title else { continue }

            if let coverData = await CoverArtService.fetchCover(title: title, author: book.author) {
                // Rows observe their Book, so the cover appears as soon as it is set
                book.coverArtData = coverData
                book.coverFromAPI = true
                print("Found cover for \"\(title)\"")
            }

            book.coverLookupAttempted = true
            coverLookupProgress += 1
            unsaved += 1

            // Each save schedules a CloudKit export, so batch them
            if unsaved >= 5 {
                PersistenceController.shared.save()
                unsaved = 0
            }

            // Rate limit: 3 seconds between books (up to 6 API calls per book)
            try? await Task.sleep(for: .seconds(3))
        }
        PersistenceController.shared.save()

        let found = candidates.filter { $0.coverArtData != nil }.count
        print("Cover lookup complete: \(found)/\(candidates.count) covers found")
    }

}
