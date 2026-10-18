import Foundation
import SwiftUI
import CoreData

/// App-level state machine that drives the root navigation.
/// States: loading -> signedOut -> needsFolder -> ready
///
/// Supports multiple libraries (Drive folders). The active library ID syncs via
/// NSUbiquitousKeyValueStore. Library entities sync via CloudKit (Core Data).
@MainActor
class AppViewModel: ObservableObject {

    enum AppState: Equatable {
        case loading
        case signedOut
        case needsFolder
        case ready
    }

    @Published var state: AppState = .loading

    /// The UUID of the currently active library, persisted in KVS + UserDefaults
    @Published var activeLibraryId: UUID?

    // Persistence key for the active library
    private let activeLibraryIdKey = "activeLibraryId"

    // Legacy keys (v1) — used only for migration
    private let legacyFolderIdKey = "selectedDriveFolderId"
    private let legacyFolderNameKey = "selectedDriveFolderName"
    private let legacyLibraryNameKey = "customLibraryName"

    /// iCloud key-value store for syncing small settings across devices
    private let kvStore = NSUbiquitousKeyValueStore.default

    /// Core Data context for Library entity operations
    private let context: NSManagedObjectContext

    init() {
        self.context = PersistenceController.shared.container.viewContext
        refreshLibraries()

        // Keep the cached list current when libraries change locally or arrive from CloudKit
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: .main
        ) { [weak self] note in
            let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey]
            let touchedLibrary = keys.contains { key in
                (note.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is Library } ?? false
            }
            if touchedLibrary {
                Task { @MainActor in self?.refreshLibraries() }
            }
        }

        // Restore active library ID from KVS first, then UserDefaults
        if let idString = kvStore.string(forKey: activeLibraryIdKey) ?? UserDefaults.standard.string(forKey: activeLibraryIdKey),
           let uuid = UUID(uuidString: idString) {
            activeLibraryId = uuid
        }

        // v1 migration: if no active library, check for legacy folder selection
        if activeLibraryId == nil {
            migrateFromV1()
        }

        // Listen for iCloud KVS changes from other devices
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleKVStoreChange()
            }
        }

        // Trigger initial sync
        kvStore.synchronize()
    }

    // MARK: - Computed Properties

    /// The currently active Library entity
    var activeLibrary: Library? {
        guard let id = activeLibraryId else { return nil }
        return allLibraries.first { $0.id == id }
    }

    /// All libraries, sorted by most recently opened first. Cached: views read this
    /// from `body`, and it used to run a Core Data fetch on every read.
    @Published private(set) var allLibraries: [Library] = []

    /// Reloads `allLibraries` from Core Data
    func refreshLibraries() {
        let request: NSFetchRequest<Library> = Library.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Library.lastOpenedDate, ascending: false)]
        allLibraries = (try? context.fetch(request)) ?? []
    }

    /// Display name for the navigation title
    var displayLibraryName: String {
        activeLibrary?.displayName ?? "Library"
    }

    // MARK: - Library Management

    /// Switches to a different library — updates active ID, timestamps, and persists
    func switchToLibrary(_ library: Library) {
        library.lastOpenedDate = Date()
        PersistenceController.shared.save()
        refreshLibraries()

        activeLibraryId = library.id
        persistActiveLibraryId()
        state = .ready
    }

    /// Adds a new library from a Drive folder. Deduplicates by folderPath.
    /// If a library with the same folder already exists, switches to it instead.
    func addLibrary(folderId: String, folderName: String) {
        // Check for duplicate
        let request: NSFetchRequest<Library> = Library.fetchRequest()
        request.predicate = NSPredicate(format: "folderPath == %@", folderId)
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            switchToLibrary(existing)
            return
        }

        // Create new library
        let library = Library(context: context)
        library.id = UUID()
        library.name = folderName
        library.folderPath = folderId
        library.createdDate = Date()
        PersistenceController.shared.save()
        refreshLibraries()

        switchToLibrary(library)
    }

    /// Removes a library and its books (cascade delete). Switches to the next
    /// available library, or goes to folder picker if none remain.
    func removeLibrary(_ library: Library) {
        let wasActive = (library.id == activeLibraryId)
        context.delete(library)
        PersistenceController.shared.save()
        refreshLibraries()

        if wasActive {
            // Pick the next available library
            if let next = allLibraries.first {
                switchToLibrary(next)
            } else {
                activeLibraryId = nil
                persistActiveLibraryId()
                state = .needsFolder
            }
        }
    }

    /// Renames the active library. Pass empty string to reset to the Drive folder name.
    func renameLibrary(_ name: String) {
        guard let library = activeLibrary else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        library.name = trimmed.isEmpty ? nil : trimmed
        PersistenceController.shared.save()
        refreshLibraries()
        objectWillChange.send()
    }

    /// Called on sign-out — clears the active library selection without deleting libraries.
    /// Libraries stay in Core Data so they're still there if the user signs back in.
    func handleSignOut() {
        activeLibraryId = nil
        persistActiveLibraryId()
    }

    /// Called when auth state changes — determines which screen to show
    func updateState(isSignedIn: Bool) {
        if !isSignedIn {
            state = .signedOut
        } else if activeLibrary != nil {
            state = .ready
        } else if let first = allLibraries.first {
            switchToLibrary(first)
        } else {
            state = .needsFolder
        }
    }

    // MARK: - Private

    /// Persists the active library ID to both KVS and UserDefaults
    private func persistActiveLibraryId() {
        if let id = activeLibraryId {
            let idString = id.uuidString
            kvStore.set(idString, forKey: activeLibraryIdKey)
            UserDefaults.standard.set(idString, forKey: activeLibraryIdKey)
        } else {
            kvStore.removeObject(forKey: activeLibraryIdKey)
            UserDefaults.standard.removeObject(forKey: activeLibraryIdKey)
        }
    }

    /// Migrates from v1 single-folder storage to multi-library.
    /// Finds the legacy folder ID, creates or finds a Library entity, and sets it as active.
    private func migrateFromV1() {
        let legacyFolderId = kvStore.string(forKey: legacyFolderIdKey)
            ?? UserDefaults.standard.string(forKey: legacyFolderIdKey)
        guard let folderId = legacyFolderId else { return }

        let folderName = kvStore.string(forKey: legacyFolderNameKey)
            ?? UserDefaults.standard.string(forKey: legacyFolderNameKey)
        let customName = kvStore.string(forKey: legacyLibraryNameKey)
            ?? UserDefaults.standard.string(forKey: legacyLibraryNameKey)

        // Find or create Library entity for the legacy folder
        let request: NSFetchRequest<Library> = Library.fetchRequest()
        request.predicate = NSPredicate(format: "folderPath == %@", folderId)
        request.fetchLimit = 1

        let library: Library
        if let existing = try? context.fetch(request).first {
            library = existing
        } else {
            library = Library(context: context)
            library.id = UUID()
            library.folderPath = folderId
            library.createdDate = Date()

            // Assign any orphaned books (books with no library) to this library
            let bookRequest: NSFetchRequest<Book> = Book.fetchRequest()
            bookRequest.predicate = NSPredicate(format: "library == nil")
            if let orphans = try? context.fetch(bookRequest) {
                for book in orphans {
                    book.library = library
                }
            }
        }

        // Apply custom name if one was set, otherwise use folder name
        if let customName = customName, !customName.isEmpty {
            library.name = customName
        } else if let folderName = folderName {
            library.name = folderName
        }

        library.lastOpenedDate = Date()
        PersistenceController.shared.save()
        refreshLibraries()

        activeLibraryId = library.id
        persistActiveLibraryId()

        // Clean up legacy keys
        for key in [legacyFolderIdKey, legacyFolderNameKey, legacyLibraryNameKey] {
            kvStore.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - iCloud KVS Sync

    /// Called when another device updates KVS — refreshes the active library
    private func handleKVStoreChange() {
        if let idString = kvStore.string(forKey: activeLibraryIdKey),
           let uuid = UUID(uuidString: idString) {
            if uuid != activeLibraryId {
                activeLibraryId = uuid
                UserDefaults.standard.set(idString, forKey: activeLibraryIdKey)
                // If the library entity exists, go to ready; otherwise it'll be picked up
                // when CloudKit syncs the Library entity
                if activeLibrary != nil {
                    state = .ready
                }
            }
        }
    }
}
