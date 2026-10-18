import Foundation
import SwiftUI
import Combine
import CoreData

/// Bridges the AudioPlayerService with the UI, manages chapter data.
/// Supports both local and streaming playback via Google Drive.
@MainActor
class PlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var currentBook: Book?
    @Published var chapters: [ChapterInfo] = []
    @Published var currentChapterIndex: Int = 0
    @Published var showChapterList: Bool = false
    @Published var bookmarks: [Bookmark] = []
    @Published var showBookmarkList: Bool = false
    @Published var showAddBookmark: Bool = false
    @Published var showFullPlayer: Bool = false
    @Published var isDiscoverMode: Bool = false

    let audioService: AudioPlayerService
    private let driveService: GoogleDriveService
    private var cancellables = Set<AnyCancellable>()
    /// Reference to the library for discover mode (set externally)
    weak var libraryVM: LibraryViewModel?

    init(audioService: AudioPlayerService, driveService: GoogleDriveService) {
        self.audioService = audioService
        self.driveService = driveService

        // Playback state (currentTime, isPlaying, ...) is observed directly from
        // AudioPlayerService by the views that need it. Forwarding it here used to
        // redraw the entire library twice a second while anything was playing.

        // Set up token-expiry retry handler
        audioService.tokenExpiryRetryHandler = { [weak self] in
            Task { @MainActor in
                self?.retryWithFreshToken()
            }
        }
    }

    // MARK: - Playback

    /// Opens a book for playback (loads chapters, starts playing).
    /// Works for both downloaded (local) and non-downloaded (streaming) books.
    func openBook(_ book: Book) {
        // Exit discover mode if opening a book normally
        if isDiscoverMode {
            isDiscoverMode = false
            audioService.skipPositionSave = false
        }
        currentBook = book
        showFullPlayer = true

        Task {
            // Credential for streaming (also used for remote chapter extraction)
            let credential = await driveService.credential(for: book.library)

            // Load chapters — from local file if downloaded, or remotely
            if book.hasChapters {
                if book.isDownloaded, let localURL = book.localFileURL {
                    chapters = await MetadataExtractor.extractChapters(from: localURL)
                } else if let driveId = book.driveFileId, let credential {
                    chapters = await MetadataExtractor.extractRemoteChapters(driveFileId: driveId, credential: credential)
                } else {
                    chapters = []
                }
            } else {
                chapters = []
            }

            loadBookmarks(for: book)
            audioService.play(book: book, credential: credential)
        }
    }

    /// Retries playback with a refreshed token when streaming fails (token expiry)
    private func retryWithFreshToken() {
        guard let book = currentBook else { return }
        Task {
            guard let credential = await driveService.credential(for: book.library) else {
                audioService.playbackError = "Could not refresh authentication. Please sign in again."
                return
            }
            audioService.play(book: book, credential: credential)
        }
    }

    /// Current chapter name based on playback position
    var currentChapterName: String? {
        guard !chapters.isEmpty else { return nil }
        let time = audioService.currentTime
        if let chapter = chapters.last(where: { $0.startTime <= time }) {
            return chapter.title
        }
        return chapters.first?.title
    }

    /// Updates the current chapter index based on playback position
    func updateCurrentChapter() {
        let time = audioService.currentTime
        if let index = chapters.lastIndex(where: { $0.startTime <= time }) {
            let oldIndex = currentChapterIndex
            currentChapterIndex = index
            // Notify sleep timer if chapter changed (for "End of Chapter" mode)
            if oldIndex != index {
                audioService.checkEndOfChapterSleep(oldChapterIndex: oldIndex, newChapterIndex: index)
            }
        }
    }

    // MARK: - Sleep Timer

    /// Sets the sleep timer
    func setSleepTimer(option: AudioPlayerService.SleepTimerOption) {
        audioService.setSleepTimer(option: option)
    }

    /// Cancels the sleep timer
    func cancelSleepTimer() {
        audioService.cancelSleepTimer()
    }

    /// Jumps to a specific chapter
    func goToChapter(_ chapter: ChapterInfo) {
        audioService.seek(to: chapter.startTime)
    }

    // MARK: - Discover Mode

    /// Starts discover mode: picks a random book, plays from a random position
    func discoverRandomBook() {
        guard let libraryVM = libraryVM else { return }
        let eligible = libraryVM.books.filter { !$0.isHidden }
        guard !eligible.isEmpty else { return }

        let randomBook = eligible.randomElement()!
        isDiscoverMode = true
        audioService.skipPositionSave = true
        currentBook = randomBook
        showFullPlayer = true

        Task {
            let credential = await driveService.credential(for: randomBook.library)

            // Load chapters if available
            if randomBook.hasChapters {
                if randomBook.isDownloaded, let localURL = randomBook.localFileURL {
                    chapters = await MetadataExtractor.extractChapters(from: localURL)
                } else if let driveId = randomBook.driveFileId, let credential {
                    chapters = await MetadataExtractor.extractRemoteChapters(driveFileId: driveId, credential: credential)
                } else {
                    chapters = []
                }
            } else {
                chapters = []
            }

            loadBookmarks(for: randomBook)
            audioService.play(book: randomBook, credential: credential)

            // Seek to a random position between 10% and 80% of duration
            if audioService.duration > 0 {
                let minPos = audioService.duration * 0.1
                let maxPos = audioService.duration * 0.8
                let randomPos = Double.random(in: minPos...maxPos)
                audioService.seek(to: randomPos)
            } else {
                // Wait briefly for duration to load, then seek
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if audioService.duration > 0 {
                    let minPos = audioService.duration * 0.1
                    let maxPos = audioService.duration * 0.8
                    let randomPos = Double.random(in: minPos...maxPos)
                    audioService.seek(to: randomPos)
                }
            }
        }
    }

    /// Exit discover mode
    func exitDiscoverMode() {
        isDiscoverMode = false
        audioService.skipPositionSave = false
        audioService.stop()
        showFullPlayer = false
        currentBook = nil
    }

    /// True if the current media is a video file
    var isVideoContent: Bool { currentBook?.isVideo ?? false }

    /// Speed display label
    var speedLabel: String {
        let rate = audioService.playbackRate
        if rate == Float(Int(rate)) {
            return "\(Int(rate))x"
        }
        return String(format: "%.2gx", rate)
    }

    // MARK: - Bookmarks

    /// Loads bookmarks for the given book from Core Data, sorted by timestamp
    func loadBookmarks(for book: Book) {
        guard let bookmarkSet = book.bookmarks as? Set<Bookmark> else {
            bookmarks = []
            return
        }
        bookmarks = bookmarkSet.sorted { $0.timestamp < $1.timestamp }
    }

    /// Adds a new bookmark at the current playback position
    func addBookmark(name: String, note: String?) {
        guard let book = currentBook else { return }
        let context = book.managedObjectContext ?? PersistenceController.shared.container.viewContext

        let bookmark = Bookmark(context: context)
        bookmark.id = UUID()
        bookmark.timestamp = audioService.currentTime
        bookmark.name = name
        bookmark.note = note
        bookmark.createdDate = Date()
        bookmark.book = book

        PersistenceController.shared.save()
        loadBookmarks(for: book)
    }

    /// Deletes a bookmark from Core Data
    func deleteBookmark(_ bookmark: Bookmark) {
        guard let book = currentBook else { return }
        let context = bookmark.managedObjectContext ?? PersistenceController.shared.container.viewContext
        context.delete(bookmark)
        PersistenceController.shared.save()
        loadBookmarks(for: book)
    }

    /// Seeks playback to a bookmark's timestamp
    func jumpToBookmark(_ bookmark: Bookmark) {
        audioService.seek(to: bookmark.timestamp)
    }
}

// Safe array indexing
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
