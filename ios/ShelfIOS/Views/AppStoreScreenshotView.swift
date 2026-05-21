import SwiftUI

enum AppStoreScreenshotMode: String {
    case library
    case player
    case drive
    case signIn

    static var current: AppStoreScreenshotMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--app-store-screenshot") else { return nil }
        let nextIndex = args.index(after: index)
        guard nextIndex < args.endIndex else { return .library }
        return AppStoreScreenshotMode(rawValue: args[nextIndex]) ?? .library
    }
}

struct AppStoreScreenshotRootView: View {
    let mode: AppStoreScreenshotMode

    var body: some View {
        switch mode {
        case .library:
            ScreenshotLibraryScreen()
        case .player:
            ScreenshotPlayerScreen()
        case .drive:
            ScreenshotDriveScreen()
        case .signIn:
            ScreenshotSignInScreen()
        }
    }
}

private struct ScreenshotBook: Identifiable {
    let id = UUID()
    let title: String
    let author: String
    let duration: String
    let progress: Double
    let isDownloaded: Bool
    let isPlaying: Bool
    let symbol: String
    let tint: Color
}

private let screenshotBooks: [ScreenshotBook] = [
    ScreenshotBook(
        title: "The Design of Everyday Things",
        author: "Don Norman",
        duration: "10h 34m",
        progress: 0.42,
        isDownloaded: true,
        isPlaying: true,
        symbol: "book.closed.fill",
        tint: .indigo
    ),
    ScreenshotBook(
        title: "A Short History of Nearly Everything",
        author: "Bill Bryson",
        duration: "18h 13m",
        progress: 0.08,
        isDownloaded: false,
        isPlaying: false,
        symbol: "globe.americas.fill",
        tint: .teal
    ),
    ScreenshotBook(
        title: "Creativity, Inc.",
        author: "Ed Catmull",
        duration: "13h 22m",
        progress: 0.0,
        isDownloaded: true,
        isPlaying: false,
        symbol: "sparkles",
        tint: .orange
    ),
    ScreenshotBook(
        title: "The Anthropocene Reviewed",
        author: "John Green",
        duration: "5h 18m",
        progress: 1.0,
        isDownloaded: true,
        isPlaying: false,
        symbol: "star.fill",
        tint: .green
    )
]

private struct ScreenshotLibraryScreen: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 18) {
                        HStack(spacing: 8) {
                            ScreenshotFilterChip(title: "All", isSelected: true)
                            ScreenshotFilterChip(title: "In Progress", isSelected: false)
                            ScreenshotFilterChip(title: "Downloaded", isSelected: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                        VStack(spacing: 0) {
                            ForEach(screenshotBooks) { book in
                                ScreenshotBookRow(book: book)
                                if book.id != screenshotBooks.last?.id {
                                    Divider().padding(.leading, 84)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 108)
                }
                .background(Color(.systemGroupedBackground))

                ScreenshotNowPlayingBar(book: screenshotBooks[0])
            }
            .navigationTitle("Audiobooks")
            .searchable(text: $searchText, prompt: "Search library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {} label: {
                        HStack(spacing: 4) {
                            Text("Library")
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

private struct ScreenshotPlayerScreen: View {
    private let book = screenshotBooks[0]

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AppColors.dragHandle)
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Spacer(minLength: 34)

            ScreenshotCover(book: book)
                .frame(width: 286, height: 286)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

            Spacer(minLength: 34)

            VStack(spacing: 6) {
                Text(book.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Chapter 12")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 8) {
                ProgressView(value: 0.42)
                    .tint(AppColors.progressFill)

                HStack {
                    Text("4:25:18")
                    Spacer()
                    Text("-6:08:42")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            HStack(spacing: 42) {
                Image(systemName: "gobackward.30")
                    .font(.system(size: 34))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 72))
                Image(systemName: "goforward.30")
                    .font(.system(size: 34))
            }
            .foregroundStyle(.primary)
            .padding(.top, 30)

            HStack {
                ScreenshotPill(text: "1.25x")
                Spacer()
                ScreenshotPill(text: "Sleep Timer", systemImage: "moon")
                Spacer()
                ScreenshotPill(text: "Offline", systemImage: "checkmark.circle.fill")
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            Spacer(minLength: 28)
        }
        .background(Color(.systemBackground))
    }
}

private struct ScreenshotDriveScreen: View {
    private let folders = [
        ("Audiobooks", "42 items"),
        ("Lectures", "16 items"),
        ("Courses", "9 items"),
        ("Downloaded for later", "7 items")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(folders, id: \.0) { folder in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.0)
                                    .font(.body)
                                Text(folder.1)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("Choose a folder to use as your Shelf library")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Downloads stay available offline")
                            Text("Shelf keeps playback progress on device and syncs your libraries through iCloud.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select This Folder") {}
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct ScreenshotSignInScreen: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Shelf")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your media, on the go")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                Text("Sign in with Google")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 40)

            Text("Shelf connects to Google Drive to access your files. Your files stay on your device after download.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
                .frame(height: 40)
        }
        .background(Color(.systemBackground))
    }
}

private struct ScreenshotBookRow: View {
    let book: ScreenshotBook

    var body: some View {
        HStack(spacing: 12) {
            ScreenshotCover(book: book)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 7) {
                    Text(book.author)
                    Text(book.duration)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if book.progress > 0 && book.progress < 1 {
                    ProgressView(value: book.progress)
                        .tint(AppColors.progressFill)
                }
            }

            Spacer()

            if book.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(AppColors.accent)
            } else if book.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.downloaded)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ScreenshotNowPlayingBar: View {
    let book: ScreenshotBook

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Rectangle()
                    .fill(AppColors.progressFill)
                    .frame(width: geo.size.width * book.progress)
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                ScreenshotCover(book: book)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)

                Image(systemName: "goforward.30")
                    .font(.body)
                    .frame(width: 36, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }
}

private struct ScreenshotCover: View {
    let book: ScreenshotBook

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [book.tint.opacity(0.95), book.tint.opacity(0.55), Color(.secondarySystemFill)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: book.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ScreenshotFilterChip: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? AppColors.accent : AppColors.secondaryFill)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
    }
}

private struct ScreenshotPill: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.subheadline)
        .fontWeight(.medium)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
