import SwiftUI

/// Root view — switches between screens based on app state
struct RootView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appVM: AppViewModel

    // Services created once and shared
    @StateObject private var audioService = AudioPlayerService()
    @State private var driveService: GoogleDriveService?
    @State private var downloadManager: DownloadManager?
    @State private var libraryVM: LibraryViewModel?
    @State private var playerVM: PlayerViewModel?

    var body: some View {
        // Fix 2: Show error screen if Core Data failed to load
        if let error = PersistenceController.loadError {
            ContentUnavailableView(
                "Database Error",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
        Group {
            switch appVM.state {
            case .loading:
                ProgressView("Loading...")

            case .signedOut:
                SignInView()

            case .needsFolder:
                if let driveService = driveService {
                    NavigationStack {
                        FolderPickerView(driveService: driveService)
                    }
                } else {
                    ProgressView("Setting up...")
                }

            case .ready:
                if let libraryVM = libraryVM, let playerVM = playerVM,
                   let downloadManager = downloadManager {
                    MainTabView()
                        .environmentObject(libraryVM)
                        .environmentObject(playerVM)
                        .environmentObject(downloadManager)
                        .environmentObject(audioService)
                } else {
                    ProgressView("Setting up...")
                }
            }
        }
        .onChange(of: auth.isSignedIn) { _, isSignedIn in
            appVM.updateState(isSignedIn: isSignedIn)
        }
        .onAppear {
            // Services need no credential to exist; each request resolves its own.
            setupServices()
            // Small delay to let Google Sign-In restore session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                appVM.updateState(isSignedIn: auth.isSignedIn)
            }
        }
        } // end else (no Core Data error)
    }

    private func setupServices() {
        guard driveService == nil else { return }
        let drive = GoogleDriveService(auth: auth)
        let download = DownloadManager(driveService: drive)
        let library = LibraryViewModel(driveService: drive, downloadManager: download)
        let player = PlayerViewModel(audioService: audioService, driveService: drive)
        player.libraryVM = library

        driveService = drive
        downloadManager = download
        libraryVM = library
        playerVM = player
    }
}

/// Main view shown when fully authenticated and folder is selected.
/// Single NavigationStack — no tab bar. Settings is accessed via a gear icon in the toolbar.
struct MainTabView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var audioService: AudioPlayerService
    /// The App Store screenshot fixture shows seeded demo books and must not reach Drive.
    var syncsWithDrive = true

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .safeAreaInset(edge: .bottom) {
            if playerVM.currentBook != nil {
                NowPlayingBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.barReveal, value: playerVM.currentBook != nil)
        .sheet(isPresented: $playerVM.showFullPlayer) {
            if playerVM.isVideoContent {
                VideoPlayerView()
            } else {
                PlayerView()
            }
        }
        .task {
            // Load books and sync on appear for the active library
            if let library = appVM.activeLibrary {
                libraryVM.loadBooks(for: library)
                if syncsWithDrive { await libraryVM.syncLibrary(library) }
            }
        }
        .onChange(of: appVM.activeLibraryId) { _, _ in
            // When the active library changes, reload books and sync
            if let library = appVM.activeLibrary {
                libraryVM.loadBooks(for: library)
                if syncsWithDrive { Task { await libraryVM.syncLibrary(library) } }
            }
        }
    }
}
