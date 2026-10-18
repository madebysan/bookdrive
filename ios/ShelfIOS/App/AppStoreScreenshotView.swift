import CoreData
import SwiftUI

// App Store and README screenshot fixture: compiled into Debug builds only.
// `--app-store-screenshot <mode>` shows the real screens over an in-memory store seeded
// with public-domain titles and plainly drawn covers. Nothing here reaches Google Drive.
#if DEBUG
enum AppStoreScreenshotMode: String {
    case library   // grid layout, light
    case player    // full player over the library
    case genres    // genre sheet over the library
    case list      // list layout, dark
    case signIn

    static var current: AppStoreScreenshotMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--app-store-screenshot") else { return nil }
        let nextIndex = args.index(after: index)
        guard nextIndex < args.endIndex else { return .library }
        return AppStoreScreenshotMode(rawValue: args[nextIndex]) ?? .library
    }

    var colorScheme: ColorScheme { self == .list ? .dark : .light }
}

struct AppStoreScreenshotRootView: View {
    let mode: AppStoreScreenshotMode

    @StateObject private var auth = GoogleAuthService()
    @StateObject private var appVM = AppViewModel()
    @StateObject private var audioService = AudioPlayerService()
    @State private var services: ScreenshotServices?

    var body: some View {
        Group {
            if mode == .signIn {
                SignInView()
            } else if let services {
                MainTabView(syncsWithDrive: false)
                    .environmentObject(services.library)
                    .environmentObject(services.player)
                    .environmentObject(services.downloads)
                    .sheet(isPresented: .constant(mode == .genres)) {
                        GenreBrowseSheet()
                            .environmentObject(services.library)
                    }
            } else {
                Color(.systemBackground)
            }
        }
        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        .environmentObject(auth)
        .environmentObject(appVM)
        .environmentObject(audioService)
        .preferredColorScheme(mode.colorScheme)
        .onAppear {
            guard mode != .signIn, services == nil else { return }
            services = ScreenshotServices(mode: mode, auth: auth, appVM: appVM, audioService: audioService)
        }
    }
}

/// The same services RootView builds, pointed at the seeded demo library.
@MainActor
private struct ScreenshotServices {
    let library: LibraryViewModel
    let player: PlayerViewModel
    let downloads: DownloadManager

    init(mode: AppStoreScreenshotMode, auth: GoogleAuthService, appVM: AppViewModel, audioService: AudioPlayerService) {
        UserDefaults.standard.set(mode != .list, forKey: "libraryLayoutIsGrid")

        let drive = GoogleDriveService(auth: auth)
        downloads = DownloadManager(driveService: drive)
        library = LibraryViewModel(driveService: drive, downloadManager: downloads)
        player = PlayerViewModel(audioService: audioService, driveService: drive)
        player.libraryVM = library

        let context = PersistenceController.shared.container.viewContext
        let (demoLibrary, nowPlaying) = DemoLibrary.seed(into: context)
        appVM.switchToLibrary(demoLibrary)

        // Paused mid-book, as if opened yesterday; no audio is loaded.
        player.currentBook = nowPlaying
        player.chapters = DemoLibrary.chapters(for: nowPlaying)
        audioService.duration = nowPlaying.duration
        audioService.currentTime = nowPlaying.playbackPosition
        player.showFullPlayer = mode == .player
    }
}

/// Public-domain titles (all have LibriVox recordings) with covers drawn here, not copied.
private enum DemoLibrary {
    struct Title {
        let title: String
        let author: String
        let genre: String
        let year: Int32
        let hours: Double
        var progress: Double = 0
        var completed = false
        var downloaded = false
        var starred = false
        let palette: (background: UInt32, ink: UInt32)
    }

    static let titles: [Title] = [
        Title(title: "Pride and Prejudice", author: "Jane Austen", genre: "Romance", year: 1813, hours: 11.6,
              progress: 0.42, downloaded: true, starred: true, palette: (0x1B6865, 0xF4EAD2)),
        Title(title: "Frankenstein", author: "Mary Shelley", genre: "Horror", year: 1818, hours: 8.35,
              downloaded: true, palette: (0x2B2D42, 0xE9D8A6)),
        Title(title: "Moby-Dick", author: "Herman Melville", genre: "Adventure", year: 1851, hours: 24.8,
              progress: 0.08, palette: (0x22416B, 0xF2E8CF)),
        Title(title: "The Adventures of Sherlock Holmes", author: "Arthur Conan Doyle", genre: "Mystery", year: 1892, hours: 10.4,
              completed: true, downloaded: true, palette: (0xC34C15, 0xFBEEDB)),
        Title(title: "Meditations", author: "Marcus Aurelius", genre: "Philosophy", year: 180, hours: 5.05,
              progress: 0.63, palette: (0xEFE4CC, 0x2E2110)),
        Title(title: "Walden", author: "Henry David Thoreau", genre: "Philosophy", year: 1854, hours: 11.85,
              palette: (0x2F5233, 0xEDE6D3)),
        Title(title: "Dracula", author: "Bram Stoker", genre: "Horror", year: 1897, hours: 15.5,
              palette: (0x6E1E1E, 0xF1E3D3)),
        Title(title: "The Odyssey", author: "Homer", genre: "Classics", year: -700, hours: 11.3,
              palette: (0xCD8F2F, 0x2E2110)),
        Title(title: "Little Women", author: "Louisa May Alcott", genre: "Fiction", year: 1868, hours: 19.0,
              palette: (0x8A5A83, 0xF7EDF2)),
        Title(title: "The Time Machine", author: "H. G. Wells", genre: "Science Fiction", year: 1895, hours: 3.4,
              completed: true, palette: (0x3E4A52, 0xD9E4E8)),
        Title(title: "Treasure Island", author: "Robert Louis Stevenson", genre: "Adventure", year: 1883, hours: 6.9,
              downloaded: true, palette: (0x4F7CAC, 0xF5F1E6)),
        Title(title: "Jane Eyre", author: "Charlotte Brontë", genre: "Romance", year: 1847, hours: 18.9,
              palette: (0x5B2A4A, 0xF0DDE6)),
        Title(title: "The War of the Worlds", author: "H. G. Wells", genre: "Science Fiction", year: 1898, hours: 6.25,
              palette: (0x1F2A30, 0xE76F51)),
        Title(title: "The Art of War", author: "Sun Tzu", genre: "Philosophy", year: -500, hours: 1.2,
              palette: (0xE9D8A6, 0x6E1E1E)),
    ]

    /// Inserts the demo library and returns it with the book shown as now playing.
    static func seed(into context: NSManagedObjectContext) -> (Library, Book) {
        let reference = Date(timeIntervalSince1970: 1_791_000_000)  // fixed, so runs match

        let library = Library(context: context)
        library.id = UUID()
        library.name = "Audiobooks"
        library.folderPath = "demo-folder"
        library.createdDate = reference
        library.lastOpenedDate = reference

        var nowPlaying: Book?
        for (index, item) in titles.enumerated() {
            let book = Book(context: context)
            book.id = UUID()
            book.library = library
            book.title = item.title
            book.author = item.author
            book.genre = item.genre
            book.year = item.year
            book.duration = item.hours * 3600
            book.playbackPosition = item.completed ? book.duration : item.progress * book.duration
            book.isCompleted = item.completed
            book.isDownloaded = item.downloaded
            book.isStarred = item.starred
            book.filePath = "\(item.author) - \(item.title).m4b"
            book.driveFileId = "demo-\(index)"
            book.fileSize = Int64(item.hours * 3600 * 8_000)  // about 64 kbps
            book.addedDate = reference.addingTimeInterval(Double(-index) * 86_400)
            book.lastPlayedDate = item.progress > 0 ? reference.addingTimeInterval(-3_600) : nil
            book.metadataLoaded = true
            book.metadataFetchDate = reference
            book.coverLookupAttempted = true
            book.hasChapters = index == 0
            book.coverArtData = cover(for: item)
            if index == 0 { nowPlaying = book }
        }
        try? context.save()
        return (library, nowPlaying!)
    }

    /// Pride and Prejudice has 61 chapters; spread them evenly.
    static func chapters(for book: Book) -> [ChapterInfo] {
        let count = 61
        let length = book.duration / Double(count)
        return (0..<count).map { ChapterInfo(title: "Chapter \($0 + 1)", startTime: Double($0) * length, duration: length) }
    }

    /// A plain typographic cover: colour field, inset frame, centred serif title, a rule, the author.
    /// Centred so the genre collages, which crop covers to their middle, keep the words.
    static func cover(for item: Title) -> Data? {
        let side: CGFloat = 600
        let background = UIColor(hex: item.palette.background)
        let ink = UIColor(hex: item.palette.ink)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            ink.withAlphaComponent(0.55).setStroke()
            let frame = UIBezierPath(rect: CGRect(x: 30, y: 30, width: side - 60, height: side - 60))
            frame.lineWidth = 3
            frame.stroke()

            let size: CGFloat = item.title.count > 18 ? 56 : 72
            let serif = UIFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
                .withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: .semibold)
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            centered.lineHeightMultiple = 0.95
            let title = NSAttributedString(string: item.title, attributes: [
                .font: serif, .foregroundColor: ink, .paragraphStyle: centered,
            ])
            let titleBox = CGRect(x: 80, y: 0, width: side - 160, height: 360)
            let titleHeight = title.boundingRect(with: titleBox.size, options: [.usesLineFragmentOrigin], context: nil).height
            title.draw(with: CGRect(x: titleBox.minX, y: 250 - titleHeight / 2, width: titleBox.width, height: titleHeight + 4),
                       options: [.usesLineFragmentOrigin], context: nil)

            ink.setFill()
            context.fill(CGRect(x: side / 2 - 30, y: 410, width: 60, height: 4))

            NSAttributedString(string: item.author.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(0.85),
                .kern: 3,
                .paragraphStyle: centered,
            ]).draw(with: CGRect(x: 60, y: 440, width: side - 120, height: 70),
                    options: [.usesLineFragmentOrigin], context: nil)
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
