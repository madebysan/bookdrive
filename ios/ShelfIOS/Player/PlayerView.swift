import SwiftUI

/// Full-screen player view
struct PlayerView: View {
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(AppColors.dragHandle)
                    .frame(width: 36, height: 5)
                Spacer()
            }
            .padding(.top, 8)

            Spacer()

            // Cover art
            if let book = playerVM.currentBook {
                Image(uiImage: book.coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 10)
            }

            Spacer()
                .frame(height: 32)

            // Title + Author
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if playerVM.isDiscoverMode {
                        Image(systemName: "shuffle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(playerVM.currentBook?.displayTitle ?? "")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                Text(playerVM.currentBook?.displayAuthor ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let chapter = playerVM.currentChapterName {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 24)

            // Scrubber
            VStack(spacing: 4) {
                Slider(
                    value: isScrubbing ? $scrubPosition : .init(
                        get: { audioService.currentTime },
                        set: { _ in }
                    ),
                    in: 0...max(audioService.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubPosition = audioService.currentTime
                        } else {
                            audioService.seek(to: scrubPosition)
                            isScrubbing = false
                        }
                    }
                )

                HStack {
                    Text(Book.formatScrubberTime(isScrubbing ? scrubPosition : audioService.currentTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text("-" + Book.formatScrubberTime(max(audioService.duration - (isScrubbing ? scrubPosition : audioService.currentTime), 0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 24)

            // Playback controls
            HStack(spacing: 40) {
                if playerVM.isDiscoverMode {
                    Button {
                        Haptics.light()
                        playerVM.exitDiscoverMode()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                    }
                } else {
                    Button {
                        Haptics.light()
                        audioService.skipBackward()
                    } label: {
                        Image(systemName: "gobackward.30")
                            .font(.title)
                    }
                }

                if audioService.isLoading {
                    ZStack {
                        Circle()
                            .fill(.primary)
                            .frame(width: 64, height: 64)
                        ProgressView()
                            .tint(Color(.systemBackground))
                            .scaleEffect(1.5)
                    }
                } else {
                    Button {
                        Haptics.medium()
                        audioService.togglePlayPause()
                    } label: {
                        Image(systemName: audioService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                }

                if playerVM.isDiscoverMode {
                    Button {
                        Haptics.light()
                        playerVM.discoverRandomBook()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                } else {
                    Button {
                        Haptics.light()
                        audioService.skipForward()
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.title)
                    }
                }
            }
            .foregroundStyle(.primary)

            Spacer()
                .frame(height: 24)

            // Speed + chapter + actions row
            HStack {
                Button {
                    cycleSpeed()
                } label: {
                    Text(playerVM.speedLabel)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                Spacer()

                // Actions menu (sleep timer, download, complete, restart)
                Menu {
                    // Sleep timer
                    Menu {
                        ForEach(AudioPlayerService.SleepTimerOption.allCases) { option in
                            Button(option.rawValue) {
                                playerVM.setSleepTimer(option: option)
                            }
                        }
                        if audioService.isSleepTimerActive {
                            Divider()
                            Button("Cancel Timer", role: .destructive) {
                                playerVM.cancelSleepTimer()
                            }
                        }
                    } label: {
                        Label(
                            audioService.isSleepTimerActive
                                ? "Sleep Timer (\(sleepTimerLabel))"
                                : "Sleep Timer",
                            systemImage: audioService.isSleepTimerActive ? "moon.fill" : "moon"
                        )
                    }

                    if let book = playerVM.currentBook {
                        Divider()

                        // Download / Remove download
                        if let driveId = book.driveFileId, downloadManager.isDownloading(driveId) {
                            Button(role: .destructive) {
                                downloadManager.cancel(driveFileId: driveId)
                            } label: {
                                Label("Cancel Download", systemImage: "xmark.circle")
                            }
                        } else if book.isDownloaded {
                            Button(role: .destructive) {
                                libraryVM.deleteDownload(for: book)
                            } label: {
                                Label("Remove Download", systemImage: "trash")
                            }
                        } else {
                            Button {
                                libraryVM.downloadBook(book)
                            } label: {
                                Label("Download for Offline", systemImage: "arrow.down.circle")
                            }
                        }

                        Divider()

                        // Star / Unstar
                        Button {
                            book.isStarred.toggle()
                            PersistenceController.shared.save()
                        } label: {
                            Label(book.isStarred ? "Remove from Watchlist" : "Add to Watchlist",
                                  systemImage: book.isStarred ? "star.slash" : "star")
                        }

                        Divider()

                        // Mark completed / restart
                        if book.isCompleted {
                            Button {
                                book.isCompleted = false
                                book.playbackPosition = 0
                                audioService.seek(to: 0)
                                PersistenceController.shared.save()
                            } label: {
                                Label("Restart Book", systemImage: "arrow.counterclockwise")
                            }
                        } else if book.playbackPosition > 0 {
                            Button {
                                book.isCompleted = true
                                PersistenceController.shared.save()
                            } label: {
                                Label("Mark Completed", systemImage: "checkmark.circle")
                            }

                            Button {
                                book.playbackPosition = 0
                                book.isCompleted = false
                                audioService.seek(to: 0)
                                PersistenceController.shared.save()
                            } label: {
                                Label("Restart Book", systemImage: "arrow.counterclockwise")
                            }
                        } else {
                            Button {
                                book.isCompleted = true
                                PersistenceController.shared.save()
                            } label: {
                                Label("Mark Completed", systemImage: "checkmark.circle")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }

                if !playerVM.chapters.isEmpty {
                    Button {
                        playerVM.showChapterList = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                    }
                    .padding(.leading, 16)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)

            // Download status indicator
            if let book = playerVM.currentBook {
                if let driveId = book.driveFileId, downloadManager.isDownloading(driveId),
                   let progress = downloadManager.activeDownloads[driveId] {
                    HStack(spacing: 8) {
                        ProgressView(value: progress.fraction)
                            .tint(.accentColor)
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                } else if book.isDownloaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                        Text("Downloaded")
                            .font(.caption2)
                    }
                    .foregroundStyle(AppColors.downloaded)
                    .padding(.top, 8)
                }
            }

            Spacer()
                .frame(height: 40)
        }
        .sheet(isPresented: $playerVM.showChapterList) {
            ChapterListSheet()
        }
        .alert("Playback Error", isPresented: .init(
            get: { audioService.playbackError != nil },
            set: { if !$0 { audioService.playbackError = nil } }
        )) {
            Button("OK") { audioService.playbackError = nil }
        } message: {
            Text(audioService.playbackError ?? "")
        }
        .onChange(of: audioService.currentTime) { _, _ in
            playerVM.updateCurrentChapter()
        }
    }

    /// Formats the sleep timer remaining time for display
    private var sleepTimerLabel: String {
        let total = Int(audioService.sleepTimerRemaining)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func cycleSpeed() {
        Haptics.selection()
        let speeds = AudioPlayerService.speeds
        let current = audioService.playbackRate
        if let idx = speeds.firstIndex(of: current) {
            let next = speeds[(idx + 1) % speeds.count]
            audioService.setSpeed(next)
        } else {
            audioService.setSpeed(1.0)
        }
    }
}

/// Chapter list sheet
struct ChapterListSheet: View {
    @EnvironmentObject var playerVM: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(playerVM.chapters) { chapter in
                    Button {
                        playerVM.goToChapter(chapter)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .foregroundStyle(.primary)
                                Text(Book.formatScrubberTime(chapter.startTime))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if playerVM.chapters[safe: playerVM.currentChapterIndex]?.id == chapter.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
