import XCTest
@testable import ShelfIOS

/// Title and author guessed from a Drive filename before any metadata is fetched.
final class FilenameParsingTests: XCTestCase {

    func testAuthorDashTitle() {
        let parsed = MetadataExtractor.parseFilename("Ursula K. Le Guin - The Dispossessed.m4b")
        XCTAssertEqual(parsed.title, "The Dispossessed")
        XCTAssertEqual(parsed.author, "Ursula K. Le Guin")
    }

    func testTitleWithAuthorInParentheses() {
        let parsed = MetadataExtractor.parseFilename("Dune (Frank Herbert).mp3")
        XCTAssertEqual(parsed.title, "Dune")
        XCTAssertEqual(parsed.author, "Frank Herbert")
    }

    func testDashPatternWinsOverParentheses() {
        let parsed = MetadataExtractor.parseFilename("Author - Title (Unabridged).m4b")
        XCTAssertEqual(parsed.title, "Title (Unabridged)")
        XCTAssertEqual(parsed.author, "Author")
    }

    func testPlainNameBecomesTitle() {
        let parsed = MetadataExtractor.parseFilename("Just a Title.flac")
        XCTAssertEqual(parsed.title, "Just a Title")
        XCTAssertNil(parsed.author)
    }

    func testNameWithoutExtension() {
        let parsed = MetadataExtractor.parseFilename("Recording")
        XCTAssertEqual(parsed.title, "Recording")
        XCTAssertNil(parsed.author)
    }

    func testExtensionOnlyYieldsNothing() {
        let parsed = MetadataExtractor.parseFilename(".m4b")
        XCTAssertNil(parsed.title)
        XCTAssertNil(parsed.author)
    }

    func testHyphenWithoutSpacesIsNotASeparator() {
        let parsed = MetadataExtractor.parseFilename("Spider-Man.mp3")
        XCTAssertEqual(parsed.title, "Spider-Man")
        XCTAssertNil(parsed.author)
    }
}
