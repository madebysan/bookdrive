import Foundation

/// How a Google Drive request is authorized: an OAuth access token from Google Sign-In.
///
/// Kept as an enum so the request-building code has one place to add a credential;
/// an anonymous API-key path existed briefly and was removed because Google throttles
/// anonymous file reads too aggressively for a library of this size.
enum DriveCredential: Equatable {
    case bearer(String)

    /// Adds the credential to a request
    func apply(to request: inout URLRequest) {
        switch self {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Direct `alt=media` URL for a file
    func mediaURL(for fileId: String) -> URL {
        URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!
    }

    /// Headers for an `AVURLAsset` built on `mediaURL`
    var assetHeaders: [String: String]? {
        switch self {
        case .bearer(let token):
            return ["Authorization": "Bearer \(token)"]
        }
    }
}
