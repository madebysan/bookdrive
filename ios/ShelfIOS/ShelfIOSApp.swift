import SwiftUI

@main
struct ShelfIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let persistence = PersistenceController.shared
    @StateObject private var auth = GoogleAuthService()
    @StateObject private var appVM = AppViewModel()
    @AppStorage("appearance") private var appearance: Int = 0

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let screenshotMode = AppStoreScreenshotMode.current {
                AppStoreScreenshotRootView(mode: screenshotMode)
                    .preferredColorScheme(.light)
            } else {
                RootView()
                    .environment(\.managedObjectContext, persistence.container.viewContext)
                    .environmentObject(auth)
                    .environmentObject(appVM)
                    .preferredColorScheme(preferredColorScheme)
                    .onOpenURL { url in
                        // Handle Google Sign-In OAuth redirect
                        _ = auth.handleURL(url)
                    }
            }
        }
    }
}
