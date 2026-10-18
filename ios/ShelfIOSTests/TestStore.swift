import CoreData
@testable import ShelfIOS

/// An empty in-memory Core Data store for one test.
///
/// Reuses the app's loaded `NSManagedObjectModel` so the process has one entity
/// description per class; loading the model a second time makes Core Data warn and
/// can resolve `Book(context:)` against the wrong model.
enum TestStore {
    static func makeContext() -> NSManagedObjectContext {
        let model = PersistenceController.shared.container.managedObjectModel
        let container = NSPersistentContainer(name: "ShelfIOSTests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        precondition(loadError == nil, "In-memory store failed to load: \(String(describing: loadError))")

        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container.viewContext
    }

    static func makeLibrary(in context: NSManagedObjectContext, name: String = "Test", folderId: String = "folder-1") -> Library {
        let library = Library(context: context)
        library.id = UUID()
        library.name = name
        library.folderPath = folderId
        library.createdDate = Date()
        return library
    }

    @discardableResult
    static func makeBook(
        in context: NSManagedObjectContext,
        library: Library? = nil,
        driveFileId: String? = nil,
        fileName: String = "Book.m4b",
        title: String? = nil,
        author: String? = nil,
        genre: String? = nil,
        duration: Double = 0,
        fileSize: Int64 = 0,
        playbackPosition: Double = 0,
        isCompleted: Bool = false,
        isHidden: Bool = false,
        isStarred: Bool = false,
        isDownloaded: Bool = false,
        rating: Int16 = 0,
        addedDate: Date = Date(),
        lastPlayedDate: Date? = nil,
        metadataLoaded: Bool = true
    ) -> Book {
        let book = Book(context: context)
        book.id = UUID()
        book.library = library
        book.driveFileId = driveFileId
        book.filePath = fileName
        book.title = title
        book.author = author
        book.genre = genre
        book.duration = duration
        book.fileSize = fileSize
        book.playbackPosition = playbackPosition
        book.isCompleted = isCompleted
        book.isHidden = isHidden
        book.isStarred = isStarred
        book.isDownloaded = isDownloaded
        book.rating = rating
        book.addedDate = addedDate
        book.lastPlayedDate = lastPlayedDate
        book.metadataLoaded = metadataLoaded
        return book
    }
}
