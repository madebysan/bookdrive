import XCTest
import CoreData
@testable import ShelfIOS

/// `LibraryViewModel.filterAndSort` builds the list the library screen shows.
@MainActor
final class LibraryFilterSortTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = TestStore.makeContext()
    }

    private func run(
        _ books: [Book],
        filter: LibraryViewModel.LibraryFilter = .all,
        genre: String? = nil,
        search: String = "",
        sort: LibraryViewModel.SortOrder = .title
    ) -> [String] {
        LibraryViewModel.filterAndSort(books, filter: filter, genre: genre, searchText: search, sortOrder: sort)
            .map(\.displayTitle)
    }

    // MARK: Filters

    func testAllHidesHiddenBooksAndHiddenShowsOnlyThem() {
        let visible = TestStore.makeBook(in: context, title: "Visible")
        let hidden = TestStore.makeBook(in: context, title: "Hidden", isHidden: true)
        XCTAssertEqual(run([visible, hidden]), ["Visible"])
        XCTAssertEqual(run([visible, hidden], filter: .hidden), ["Hidden"])
    }

    func testInProgressNeedsPositionAndNotCompleted() {
        let started = TestStore.makeBook(in: context, title: "Started", playbackPosition: 10)
        let finished = TestStore.makeBook(in: context, title: "Finished", playbackPosition: 10, isCompleted: true)
        let untouched = TestStore.makeBook(in: context, title: "Untouched")
        XCTAssertEqual(run([started, finished, untouched], filter: .inProgress), ["Started"])
        XCTAssertEqual(run([started, finished, untouched], filter: .completed), ["Finished"])
        XCTAssertEqual(run([started, finished, untouched], filter: .notStarted), ["Untouched"])
    }

    func testStarredDownloadedAndQuickListens() {
        let starred = TestStore.makeBook(in: context, title: "Starred", isStarred: true)
        let downloaded = TestStore.makeBook(in: context, title: "Downloaded", isDownloaded: true)
        let short = TestStore.makeBook(in: context, title: "Short", duration: 2 * 3600)
        let long = TestStore.makeBook(in: context, title: "Long", duration: 9 * 3600)
        let unknown = TestStore.makeBook(in: context, title: "Unknown", duration: 0)
        let all = [starred, downloaded, short, long, unknown]
        XCTAssertEqual(run(all, filter: .starred), ["Starred"])
        XCTAssertEqual(run(all, filter: .downloaded), ["Downloaded"])
        XCTAssertEqual(run(all, filter: .quickListens), ["Short"])
    }

    func testRecentlyAddedUsesSevenDayWindow() {
        let fresh = TestStore.makeBook(in: context, title: "Fresh", addedDate: Date())
        let old = TestStore.makeBook(in: context, title: "Old", addedDate: Date().addingTimeInterval(-30 * 86400))
        XCTAssertEqual(run([fresh, old], filter: .recentlyAdded), ["Fresh"])
    }

    func testGenreAndSearchNarrowTheList() {
        let scifi = TestStore.makeBook(in: context, title: "Dune", author: "Frank Herbert", genre: "Sci-Fi")
        let fantasy = TestStore.makeBook(in: context, title: "The Hobbit", author: "J. R. R. Tolkien", genre: "Fantasy")
        XCTAssertEqual(run([scifi, fantasy], genre: "Fantasy"), ["The Hobbit"])
        XCTAssertEqual(run([scifi, fantasy], search: "herbert"), ["Dune"])
        XCTAssertEqual(run([scifi, fantasy], search: "HOBBIT"), ["The Hobbit"])
        XCTAssertEqual(run([scifi, fantasy], search: "nothing"), [])
    }

    func testSearchFallsBackToFilenameTitle() {
        let untitled = TestStore.makeBook(in: context, fileName: "Some Audiobook.m4b")
        XCTAssertEqual(run([untitled], search: "audiobook"), ["Some Audiobook"])
    }

    // MARK: Sorting

    func testTitleSortIsCaseInsensitive() {
        let b = TestStore.makeBook(in: context, title: "banana")
        let a = TestStore.makeBook(in: context, title: "Apple")
        let c = TestStore.makeBook(in: context, title: "cherry")
        XCTAssertEqual(run([b, a, c]), ["Apple", "banana", "cherry"])
    }

    func testRatingSortPutsUnratedLastAndBreaksTiesByTitle() {
        let five = TestStore.makeBook(in: context, title: "Five", rating: 100)
        let threeB = TestStore.makeBook(in: context, title: "Three B", rating: 60)
        let threeA = TestStore.makeBook(in: context, title: "Three A", rating: 60)
        let unrated = TestStore.makeBook(in: context, title: "Aaa Unrated", rating: 0)
        XCTAssertEqual(run([unrated, threeB, five, threeA], sort: .rating), ["Five", "Three A", "Three B", "Aaa Unrated"])
    }

    func testDurationSortsPutUnknownDurationLast() {
        let short = TestStore.makeBook(in: context, title: "Short", duration: 100)
        let long = TestStore.makeBook(in: context, title: "Long", duration: 900)
        let unknown = TestStore.makeBook(in: context, title: "Unknown", duration: 0)
        XCTAssertEqual(run([unknown, long, short], sort: .shortest), ["Short", "Long", "Unknown"])
        XCTAssertEqual(run([unknown, short, long], sort: .longest), ["Long", "Short", "Unknown"])
    }

    func testFileSizeSortsPutUnknownSizeLast() {
        let big = TestStore.makeBook(in: context, title: "Big", fileSize: 5_000)
        let small = TestStore.makeBook(in: context, title: "Small", fileSize: 100)
        let unknown = TestStore.makeBook(in: context, title: "Unknown", fileSize: 0)
        XCTAssertEqual(run([unknown, small, big], sort: .largestFile), ["Big", "Small", "Unknown"])
        XCTAssertEqual(run([unknown, big, small], sort: .smallestFile), ["Small", "Big", "Unknown"])
    }

    func testRecentSortOrdersByLastPlayedDescendingWithNeverPlayedLast() {
        let now = Date()
        let today = TestStore.makeBook(in: context, title: "Today", lastPlayedDate: now)
        let yesterday = TestStore.makeBook(in: context, title: "Yesterday", lastPlayedDate: now.addingTimeInterval(-86400))
        let never = TestStore.makeBook(in: context, title: "Never")
        XCTAssertEqual(run([never, yesterday, today], sort: .recent), ["Today", "Yesterday", "Never"])
    }

    func testSubfolderSortGroupsBySubfolderWithRootLast() {
        let a1 = TestStore.makeBook(in: context, title: "Zed")
        a1.subfolderName = "Alpha"
        let b1 = TestStore.makeBook(in: context, title: "Amy")
        b1.subfolderName = "Beta"
        let root = TestStore.makeBook(in: context, title: "Aardvark")
        XCTAssertEqual(run([root, b1, a1], sort: .subfolder), ["Zed", "Amy", "Aardvark"])
    }
}
