import XCTest
@testable import ShelfIOS

final class WorkQueueTests: XCTestCase {

    func testEnqueuePreservesOrderAndDeduplicates() {
        var queue = WorkQueue<String>()
        queue.enqueue(contentsOf: ["a", "b", "c", "b"])
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.popFirst(), "a")
        XCTAssertEqual(queue.popFirst(), "b")
        XCTAssertEqual(queue.popFirst(), "c")
        XCTAssertNil(queue.popFirst())
    }

    func testPrioritizeMovesQueuedKeyToFront() {
        var queue = WorkQueue<String>()
        queue.enqueue(contentsOf: ["a", "b", "c"])
        queue.prioritize("c")
        XCTAssertEqual(queue.popFirst(), "c")
        XCTAssertEqual(queue.popFirst(), "a")
    }

    func testPrioritizeIgnoresUnknownAndFinishedKeys() {
        var queue = WorkQueue<String>()
        queue.enqueue(contentsOf: ["a", "b"])
        _ = queue.popFirst()
        queue.prioritize("a")   // already finished
        queue.prioritize("zzz") // never queued
        XCTAssertEqual(queue.count, 1)
        XCTAssertFalse(queue.contains("a"))
        XCTAssertEqual(queue.popFirst(), "b")
    }

    func testRemoveAllEmptiesQueue() {
        var queue = WorkQueue<Int>()
        queue.enqueue(contentsOf: 1...5)
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())
    }
}
