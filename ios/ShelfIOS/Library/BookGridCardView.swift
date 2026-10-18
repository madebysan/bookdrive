import SwiftUI

/// A grid card for the 2-column library layout — large cover with title, author, and duration below.
/// Replicates all actions from BookRowView via context menu (since swipe actions don't work on grids).
struct BookGridCardView: View {
    @ObservedObject var book: Book
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playerVM: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Cover image with overlays
            coverImage

            // Title, author, duration — fixed height so cards align across rows
            VStack(alignment: .leading, spacing: 2) {
                Text(book.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(book.metadataLoaded ? book.displayAuthor : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if book.duration > 0 {
                    Text(book.formattedDuration)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if book.fileSize > 0 {
                    Text(book.formattedFileSize)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(" ")
                        .font(.caption2)
                }
            }
            .frame(height: 62, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap()
        }
        .onAppear {
            libraryVM.prioritizeEnrichment(for: book)
        }
        .contextMenu {
            // Star / Unstar
            Button {
                Haptics.light()
                book.isStarred.toggle()
                PersistenceController.shared.save()
            } label: {
                Label(book.isStarred ? "Unstar" : "Star", systemImage: book.isStarred ? "star.slash" : "star")
            }

            // Hide / Unhide
            Button {
                Haptics.light()
                book.isHidden.toggle()
                PersistenceController.shared.save()
            } label: {
                Label(book.isHidden ? "Unhide" : "Hide", systemImage: book.isHidden ? "eye" : "eye.slash")
            }

            // Cancel while downloading; Download for books not on the device
            if libraryVM.isDownloading(book) {
                Button(role: .destructive) {
                    Haptics.light()
                    libraryVM.cancelDownload(for: book)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } else if !book.isDownloaded {
                Button {
                    Haptics.medium()
                    libraryVM.downloadBook(book)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }

            // Mark completed / unfinished
            Button {
                Haptics.success()
                book.isCompleted.toggle()
                PersistenceController.shared.save()
            } label: {
                if book.isCompleted {
                    Label("Mark Unfinished", systemImage: "arrow.uturn.backward")
                } else {
                    Label("Mark Completed", systemImage: "checkmark.circle")
                }
            }

            // Restart (only if there's progress)
            if book.playbackPosition > 0 || book.isCompleted {
                Button(role: .destructive) {
                    Haptics.medium()
                    book.playbackPosition = 0
                    book.isCompleted = false
                    PersistenceController.shared.save()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
            }

            if book.coverArtData != nil {
                Button(role: .destructive) {
                    libraryVM.clearCover(for: book)
                } label: {
                    Label("Clear Cover", systemImage: "photo.badge.minus")
                }
            }

            // Refresh metadata
            Button {
                Task { await libraryVM.fetchMetadataForBook(book) }
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.trianglehead.2.clockwise")
            }
        }
    }

    // MARK: - Cover Image

    /// True when the cover image is roughly square (within 10% tolerance)
    private var coverIsSquare: Bool {
        let img = book.coverImage
        guard img.size.width > 0, img.size.height > 0 else { return true }
        let ratio = img.size.width / img.size.height
        return ratio > 0.9 && ratio < 1.1
    }

    private var coverImage: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if coverIsSquare {
                    // Square cover — fill directly
                    Image(uiImage: book.coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Non-square — blurred background + centered fit
                    ZStack {
                        Image(uiImage: book.coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 20)

                        Image(uiImage: book.coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                // Video badge — only shown for video items
                if book.isVideo {
                    Image(systemName: "film")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                BookGridStatusBadge(book: book)
                    .padding(6)
            }
            .overlay(alignment: .bottom) {
                // Progress bar at bottom edge
                if book.progress > 0 && book.progress < 1 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(AppColors.progressFill)
                            .frame(width: geo.size.width * book.progress, height: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
    }

    // MARK: - Tap

    private func handleTap() {
        if libraryVM.isDownloading(book) {
            return
        }
        playerVM.openBook(book)
    }
}

/// Download ring, now-playing dot, or downloaded checkmark.
/// Kept as its own view so download progress redraws only this badge.
private struct BookGridStatusBadge: View {
    @ObservedObject var book: Book
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        Group {
            if let driveId = book.driveFileId, downloadManager.isDownloading(driveId) {
                // Downloading ring
                if let progress = downloadManager.activeDownloads[driveId] {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 26, height: 26)
                        Circle()
                            .trim(from: 0, to: progress.fraction)
                            .stroke(AppColors.progressFill, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 20)
                    }
                }
            } else if playerVM.currentBook?.objectID == book.objectID {
                // Playing indicator
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(5)
                    .background(AppColors.accent, in: Circle())
            } else if book.isDownloaded {
                // Downloaded checkmark
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(5)
                    .background(AppColors.downloaded, in: Circle())
            }
        }
        .animation(AppAnimation.statusChange, value: book.isDownloaded)
    }
}
