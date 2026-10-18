import XCTest
import CoreData
@testable import ShelfIOS

/// The progress JSON is the one format macOS, iOS, and Android all read and write.
/// These tests pin its shape as much as its behavior.
final class ProgressExporterTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = TestStore.makeContext()
    }

    private func exportFixture() -> Data {
        let played = TestStore.makeBook(in: context, fileName: "Dune.m4b", playbackPosition: 1234.5, lastPlayedDate: Date(timeIntervalSince1970: 1_700_000_000))
        let bookmark = Bookmark(context: context)
        bookmark.id = UUID()
        bookmark.timestamp = 600
        bookmark.name = "Chapter 2"
        bookmark.note = "Great scene"
        bookmark.createdDate = Date(timeIntervalSince1970: 1_700_000_100)
        bookmark.book = played

        let finished = TestStore.makeBook(in: context, fileName: "Hobbit.mp3", playbackPosition: 99, isCompleted: true, lastPlayedDate: Date(timeIntervalSince1970: 1_690_000_000))

        return ProgressExporter.exportProgress(books: [played, finished])!
    }

    // MARK: Format contract

    func testExportedJSONHasTheCrossPlatformShape() throws {
        let data = exportFixture()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(root.keys), ["books", "exportDate", "version"])
        XCTAssertEqual(root["version"] as? String, "1.0")
        XCTAssertNotNil(root["exportDate"] as? String, "dates are ISO 8601 strings")

        let books = try XCTUnwrap(root["books"] as? [[String: Any]])
        XCTAssertEqual(books.count, 2)
        let dune = try XCTUnwrap(books.first { $0["filePath"] as? String == "Dune.m4b" })
        XCTAssertEqual(Set(dune.keys), ["bookmarks", "filePath", "isCompleted", "lastPlayedDate", "playbackPosition"])
        XCTAssertEqual(dune["playbackPosition"] as? Double, 1234.5)
        XCTAssertEqual(dune["isCompleted"] as? Bool, false)
        XCTAssertEqual(dune["lastPlayedDate"] as? String, "2023-11-14T22:13:20Z")

        let bookmarks = try XCTUnwrap(dune["bookmarks"] as? [[String: Any]])
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(Set(bookmarks[0].keys), ["createdDate", "name", "note", "timestamp"])
        XCTAssertEqual(bookmarks[0]["timestamp"] as? Double, 600)
        XCTAssertEqual(bookmarks[0]["name"] as? String, "Chapter 2")
    }

    // MARK: Round trip

    func testImportRestoresProgressAndBookmarksByFilePath() throws {
        let data = exportFixture()

        let target = TestStore.makeContext()
        let dune = TestStore.makeBook(in: target, fileName: "Dune.m4b")
        let hobbit = TestStore.makeBook(in: target, fileName: "Hobbit.mp3")
        TestStore.makeBook(in: target, fileName: "Unrelated.m4b")

        let result = try XCTUnwrap(ProgressExporter.importProgress(from: data, context: target))
        XCTAssertEqual(result.booksUpdated, 2)
        XCTAssertEqual(result.bookmarksCreated, 1)
        XCTAssertEqual(result.booksNotFound, 0)

        XCTAssertEqual(dune.playbackPosition, 1234.5)
        XCTAssertEqual(dune.lastPlayedDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(dune.isCompleted)
        XCTAssertTrue(hobbit.isCompleted)
        XCTAssertEqual(hobbit.playbackPosition, 99)

        let bookmarks = try XCTUnwrap(dune.bookmarks as? Set<Bookmark>)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.name, "Chapter 2")
        XCTAssertEqual(bookmarks.first?.note, "Great scene")
        XCTAssertFalse(target.hasChanges, "import saves the context")
    }

    func testImportingTwiceDoesNotDuplicateBookmarks() throws {
        let data = exportFixture()
        let target = TestStore.makeContext()
        TestStore.makeBook(in: target, fileName: "Dune.m4b")

        _ = ProgressExporter.importProgress(from: data, context: target)
        let second = try XCTUnwrap(ProgressExporter.importProgress(from: data, context: target))
        XCTAssertEqual(second.bookmarksCreated, 0)
        XCTAssertEqual(second.booksUpdated, 1)
        XCTAssertEqual(second.booksNotFound, 1)
    }

    func testMalformedDataIsRejected() {
        XCTAssertNil(ProgressExporter.importProgress(from: Data("not json".utf8), context: context))
        XCTAssertNil(ProgressExporter.importProgress(from: Data("{\"version\":\"1.0\"}".utf8), context: context))
    }
}
