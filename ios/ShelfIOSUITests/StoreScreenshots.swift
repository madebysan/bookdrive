import XCTest

/// App Store and README capture. `scripts/store-screenshots/generate.sh` runs this, exports the named
/// attachments and frames them. Attachment names match the `capture` keys in `scripts/store-screenshots/slots.json`.
/// Each slot is a fresh launch of the Debug-only screenshot mode (`--app-store-screenshot <mode>`), which shows
/// the real screens over an in-memory library of public-domain demo books.
final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { XCUIApplication().terminate() }

    @MainActor
    func testCaptureStoreSet() {
        let library = launch("library")
        XCTAssertTrue(library.staticTexts["Dracula"].waitForExistence(timeout: 10))
        XCTAssertTrue(library.staticTexts["Pride and Prejudice"].exists)
        capture(library, name: "library")

        let player = launch("player")
        XCTAssertTrue(player.staticTexts["Chapter 26"].waitForExistence(timeout: 10))
        capture(player, name: "player")

        let genres = launch("genres")
        XCTAssertTrue(genres.staticTexts["Philosophy"].waitForExistence(timeout: 10))
        capture(genres, name: "genres")

        let list = launch("list")
        XCTAssertTrue(list.staticTexts["Frankenstein"].waitForExistence(timeout: 10))
        capture(list, name: "list")

        let signIn = launch("signIn")
        XCTAssertTrue(signIn.staticTexts["Welcome to Bookdrive"].waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.buttons["Sign in with Google"].exists)
        capture(signIn, name: "signIn")
    }

    @MainActor
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--app-store-screenshot", mode]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        // Let sheets settle and entrance animations finish.
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
