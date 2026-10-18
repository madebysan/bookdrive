import AVKit
import SwiftUI

/// Video player view — portrait split layout with system fullscreen via AVPlayerViewController
struct VideoPlayerView: View {
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var audioService: AudioPlayerService
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        normalLayout
    }

    // MARK: - Normal Layout (portrait split view)

    private var normalLayout: some View {
        VStack(spacing: 0) {
            // Drag handle
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 36, height: 5)
                Spacer()
            }
            .padding(.top, 8)

            Spacer()
                .frame(height: 16)

            // Video area — tap to enter fullscreen
            videoArea
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .onTapGesture {
                    presentSystemFullscreen()
                }

            Spacer()
                .frame(height: 20)

            // Title, author, chapter
            VStack(spacing: 4) {
                Text(playerVM.currentBook?.displayTitle ?? "")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

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

            // Discover mode banner
            if playerVM.isDiscoverMode {
                discoverBanner
            }

            Spacer()
                .frame(height: 24)

            // Scrubber
            scrubber

            Spacer()
                .frame(height: 24)

            // Playback controls
            HStack(spacing: 40) {
                Button { audioService.skipBackward() } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title)
                }

                Button { audioService.togglePlayPause() } label: {
                    Image(systemName: audioService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }

                Button { audioService.skipForward() } label: {
                    Image(systemName: "goforward.10")
                        .font(.title)
                }
            }
            .foregroundStyle(.primary)

            Spacer()
                .frame(height: 24)

            // Speed + actions row
            actionsRow

            // Download status
            downloadStatus

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

    // MARK: - Shared Components

    private var videoArea: some View {
        ZStack {
            Color.black

            if let player = audioService.avPlayer {
                VideoLayerView(player: player)
            }

            // Fullscreen hint icon
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(6)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
        }
    }

    private var scrubber: some View {
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
    }

    private var actionsRow: some View {
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
                            Label("Restart", systemImage: "arrow.counterclockwise")
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
                            Label("Restart", systemImage: "arrow.counterclockwise")
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
    }

    @ViewBuilder
    private var downloadStatus: some View {
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
                .foregroundStyle(.green)
                .padding(.top, 8)
            }
        }
    }

    private var discoverBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "shuffle")
                .font(.caption)
            Text("Discover Mode \u{2014} progress not saved")
                .font(.caption)
            Spacer()
            Button("Next") {
                playerVM.discoverRandomBook()
            }
            .font(.caption)
            .fontWeight(.medium)
            Button("Exit") {
                playerVM.exitDiscoverMode()
            }
            .font(.caption)
            .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var sleepTimerLabel: String {
        let total = Int(audioService.sleepTimerRemaining)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func cycleSpeed() {
        let speeds = AudioPlayerService.speeds
        let current = audioService.playbackRate
        if let idx = speeds.firstIndex(of: current) {
            let next = speeds[(idx + 1) % speeds.count]
            audioService.setSpeed(next)
        } else {
            audioService.setSpeed(1.0)
        }
    }

    /// Presents the system AVPlayerViewController for true fullscreen with rotation support
    private func presentSystemFullscreen() {
        guard let player = audioService.avPlayer else { return }

        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.modalPresentationStyle = .fullScreen

        AppDelegate.allowLandscape = true

        // Walk to the topmost presented view controller (same pattern as SettingsView)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        presenter.present(playerVC, animated: true)

        // Monitor for dismissal, then clean up
        Task { @MainActor in
            while playerVC.presentingViewController != nil {
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Detach player so VideoLayerView re-captures it on next render
            playerVC.player = nil
            AppDelegate.allowLandscape = false
        }
    }
}
