import XCTest
@testable import ShelfIOS

/// Request authorization and Drive item classification for the Drive source.
final class DriveAccessTests: XCTestCase {

    // MARK: Credentials

    func testBearerCredentialUsesAuthorizationHeader() {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        DriveCredential.bearer("tok").apply(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertFalse(request.url!.absoluteString.contains("key="))
    }

    func testMediaURLAndAssetHeaders() {
        let credential = DriveCredential.bearer("tok")
        XCTAssertTrue(credential.mediaURL(for: "file1").absoluteString.hasSuffix("/files/file1?alt=media"))
        XCTAssertEqual(credential.assetHeaders, ["Authorization": "Bearer tok"])
    }

    // MARK: Drive items

    func testMediaDetectionByMimeTypeAndExtension() {
        XCTAssertTrue(DriveItem(id: "1", name: "a", mimeType: "audio/mpeg", size: 1, modifiedTime: nil).isMediaFile)
        XCTAssertTrue(DriveItem(id: "2", name: "book.m4b", mimeType: "application/octet-stream", size: 1, modifiedTime: nil).isMediaFile)
        XCTAssertFalse(DriveItem(id: "3", name: "notes.txt", mimeType: "text/plain", size: 1, modifiedTime: nil).isMediaFile)

        let folder = DriveItem(id: "4", name: "Folder", mimeType: "application/vnd.google-apps.folder", size: nil, modifiedTime: nil)
        XCTAssertTrue(folder.isFolder)
        XCTAssertFalse(folder.isMediaFile)
    }
}
