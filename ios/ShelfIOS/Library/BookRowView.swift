import SwiftUI

/// A single audiobook row in the library list
struct BookRowView: View {
    @ObservedObject var book: Book
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playerVM: PlayerViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Cover art thumbnail with video badge
            Image(uiImage: book.thumbnailImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if book.isVideo {
                        Image(systemName: "film")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(3)
                    }
                }

            // Title + subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text(book.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if book.metadataLoaded {
                        Text(book.displayAuthor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if book.duration > 0 {
                        Text(book.formattedDuration)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if book.fileSize > 0 {
                        Text(book.formattedFileSize)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Progress bar (only for books with progress)
                if book.progress > 0 && book.progress < 1 {
                    ProgressView(value: book.progress)
                        .tint(.accentColor)
                }
            }

            Spacer()

            // Right side: status indicator (observes DownloadManager on its own)
            BookRowStatusIndicator(book: book)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap()
        }
        .onAppear {
            libraryVM.prioritizeEnrichment(for: book)
        }
        .contextMenu {
            Button {
                book.isStarred.toggle()
                PersistenceController.shared.save()
            } label: {
                Label(book.isStarred ? "Unstar" : "Star", systemImage: book.isStarred ? "star.slash" : "star")
            }

            Button {
                book.isHidden.toggle()
                PersistenceController.shared.save()
            } label: {
                Label(book.isHidden ? "Unhide" : "Hide", systemImage: book.isHidden ? "eye" : "eye.slash")
            }

            if book.coverArtData != nil {
                Button(role: .destructive) {
                    libraryVM.clearCover(for: book)
                } label: {
                    Label("Clear Cover", systemImage: "photo.badge.minus")
                }
            }

            Button {
                Task { await libraryVM.fetchMetadataForBook(book) }
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.trianglehead.2.clockwise")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if libraryVM.filter == .hidden {
                Button {
                    Haptics.light()
                    book.isHidden = false
                    PersistenceController.shared.save()
                } label: {
                    Label("Unhide", systemImage: "eye")
                }
                .tint(.blue)
            } else {
                Button {
                    Haptics.light()
                    book.isHidden = true
                    PersistenceController.shared.save()
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .tint(.gray)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Download for offline (only for non-downloaded books)
            if !book.isDownloaded {
                Button {
                    Haptics.medium()
                    libraryVM.downloadBook(book)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }

            // Mark completed / unfinished toggle
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
            .tint(book.isCompleted ? .orange : .green)

            // Restart progress (only shown if there's progress to reset)
            if book.playbackPosition > 0 || book.isCompleted {
                Button {
                    Haptics.medium()
                    book.playbackPosition = 0
                    book.isCompleted = false
                    PersistenceController.shared.save()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
                .tint(.red)
            }
        }
    }

    /// Tapping any book always opens it for playback (streams if not downloaded)
    private func handleTap() {
        if libraryVM.isDownloading(book) {
            // Don't interrupt an active download
            return
        }
        playerVM.openBook(book)
    }
}

/// Download ring, now-playing speaker, or downloaded checkmark.
/// Kept as its own view so download progress redraws only this badge.
private struct BookRowStatusIndicator: View {
    @ObservedObject var book: Book
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        Group {
            if let driveId = book.driveFileId, downloadManager.isDownloading(driveId) {
                // Downloading — show progress ring
                if let progress = downloadManager.activeDownloads[driveId] {
                    ZStack {
                        Circle()
                            .stroke(AppColors.progressTrack, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: progress.fraction)
                            .stroke(AppColors.progressFill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Button {
                            downloadManager.cancel(driveFileId: driveId)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                    }
                    .frame(width: 32, height: 32)
                }
            } else if playerVM.currentBook?.objectID == book.objectID {
                // Currently playing
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(AppColors.accent)
                    .font(.body)
            } else if book.isDownloaded {
                // Downloaded — show checkmark
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.downloaded)
                    .font(.body)
            }
            // Non-downloaded books show nothing — they stream on tap
        }
        .animation(AppAnimation.statusChange, value: book.isDownloaded)
    }
}
