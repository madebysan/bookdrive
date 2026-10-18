import XCTest
import CoreData
@testable import ShelfIOS

/// Reconciling a Drive listing with the books stored for one library.
final class LibrarySyncTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private var library: Library!

    override func setUp() {
        super.setUp()
        context = TestStore.makeContext()
        library = TestStore.makeLibrary(in: context)
    }

    private func file(_ id: String, _ name: String, size: Int64? = 1_000) -> DriveItem {
        DriveItem(id: id, name: name, mimeType: "audio/mp4", size: size, modifiedTime: nil)
    }

    private func books() -> [Book] {
        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        return (try? context.fetch(request)) ?? []
    }

    func testNewFilesBecomeBooksWithParsedTitles() {
        let outcome = LibrarySync.reconcile(
            driveResults: [
                (file: file("f1", "Frank Herbert - Dune.m4b"), subfolder: nil),
                (file: file("f2", "Dune Messiah.mp3", size: 42), subfolder: "Sequels"),
            ],
            library: library,
            context: context
        )

        XCTAssertEqual(outcome, LibrarySync.Outcome(listed: 2, added: 2, removed: 0))
        let stored = books().sorted { ($0.driveFileId ?? "") < ($1.driveFileId ?? "") }
        XCTAssertEqual(stored.count, 2)

        XCTAssertEqual(stored[0].title, "Dune")
        XCTAssertEqual(stored[0].author, "Frank Herbert")
        XCTAssertEqual(stored[0].filePath, "Frank Herbert - Dune.m4b")
        XCTAssertNil(stored[0].subfolderName)
        XCTAssertTrue(stored[0].metadataLoaded)
        XCTAssertFalse(stored[0].isDownloaded)
        XCTAssertNotNil(stored[0].id)
        XCTAssertNotNil(stored[0].addedDate)

        XCTAssertEqual(stored[1].title, "Dune Messiah")
        XCTAssertNil(stored[1].author)
        XCTAssertEqual(stored[1].fileSize, 42)
        XCTAssertEqual(stored[1].subfolderName, "Sequels")
    }

    func testDuplicateListingsCreateOneBook() {
        LibrarySync.reconcile(
            driveResults: [
                (file: file("f1", "Book.m4b"), subfolder: nil),
                (file: file("f1", "Book.m4b"), subfolder: "Mirror"),
            ],
            library: library,
            context: context
        )
        XCTAssertEqual(books().count, 1)
    }

    func testExistingBooksKeepProgressAndPickUpSizeAndSubfolderChanges() {
        let existing = TestStore.makeBook(in: context, library: library, driveFileId: "f1", fileName: "Book.m4b", title: "Book", fileSize: 10, playbackPosition: 300)
        existing.subfolderName = "Old"

        let outcome = LibrarySync.reconcile(
            driveResults: [(file: file("f1", "Book.m4b", size: 20), subfolder: "New")],
            library: library,
            context: context
        )

        XCTAssertEqual(outcome, LibrarySync.Outcome(listed: 1, added: 0, removed: 0))
        XCTAssertEqual(books().count, 1)
        XCTAssertEqual(existing.fileSize, 20)
        XCTAssertEqual(existing.subfolderName, "New")
        XCTAssertEqual(existing.playbackPosition, 300)
        XCTAssertEqual(existing.title, "Book")
    }

    func testBooksMissingFromDriveAreRemovedOnlyWithinThisLibrary() {
        TestStore.makeBook(in: context, library: library, driveFileId: "gone", fileName: "Gone.m4b")
        let kept = TestStore.makeBook(in: context, library: library, driveFileId: "f1", fileName: "Kept.m4b")
        let otherLibrary = TestStore.makeLibrary(in: context, name: "Other", folderId: "folder-2")
        let elsewhere = TestStore.makeBook(in: context, library: otherLibrary, driveFileId: "gone", fileName: "Gone.m4b")

        let outcome = LibrarySync.reconcile(
            driveResults: [(file: file("f1", "Kept.m4b"), subfolder: nil)],
            library: library,
            context: context
        )

        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(books().map(\.objectID), [kept.objectID])
        XCTAssertFalse(elsewhere.isDeleted)
    }

    func testLegacyBooksWithoutParsedMetadataGetTitlesFilledIn() {
        let legacy = TestStore.makeBook(in: context, library: library, driveFileId: "f1", fileName: "Author - Title.m4b", metadataLoaded: false)
        let customised = TestStore.makeBook(in: context, library: library, driveFileId: "f2", fileName: "Other - Name.m4b", title: "My Title", metadataLoaded: false)

        LibrarySync.reconcile(
            driveResults: [
                (file: file("f1", "Author - Title.m4b"), subfolder: nil),
                (file: file("f2", "Other - Name.m4b"), subfolder: nil),
            ],
            library: library,
            context: context
        )

        XCTAssertEqual(legacy.title, "Title")
        XCTAssertEqual(legacy.author, "Author")
        XCTAssertTrue(legacy.metadataLoaded)
        XCTAssertEqual(customised.title, "My Title")
        XCTAssertEqual(customised.author, "Other")
        XCTAssertTrue(customised.metadataLoaded)
    }

    func testReconcileDoesNotSave() {
        LibrarySync.reconcile(
            driveResults: [(file: file("f1", "Book.m4b"), subfolder: nil)],
            library: library,
            context: context
        )
        XCTAssertTrue(context.hasChanges)
    }
}
