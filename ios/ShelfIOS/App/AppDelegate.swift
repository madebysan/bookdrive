import UIKit

/// Handles background URLSession events that arrive when the app is relaunched
/// by the system to process completed background downloads.
class AppDelegate: NSObject, UIApplicationDelegate {

    /// Controls whether landscape rotation is allowed (true during fullscreen video)
    static var allowLandscape = false

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Store the completion handler so DownloadManager can call it
        // after processing all background download events
        BackgroundSessionRegistry.shared.completionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return Self.allowLandscape ? .allButUpsideDown : .portrait
    }
}
