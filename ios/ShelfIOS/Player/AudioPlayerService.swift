import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Manages audio and video playback using AVPlayer with Now Playing and remote command integration.
/// Supports both local files and streaming from Google Drive with authenticated AVURLAsset.
@MainActor
class AudioPlayerService: ObservableObject {

    // MARK: - Published State

    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var playbackError: String?

    // MARK: - Sleep Timer

    @Published var sleepTimerRemaining: TimeInterval = 0
    @Published var isSleepTimerActive: Bool = false

    /// Options for the sleep timer
    enum SleepTimerOption: String, CaseIterable, Identifiable {
        case fifteen = "15 min"
        case thirty = "30 min"
        case fortyFive = "45 min"
        case sixty = "1 hour"
        case endOfChapter = "End of Chapter"

        var id: String { rawValue }

        /// Minutes for timed options, nil for End of Chapter
        var minutes: Int? {
            switch self {
            case .fifteen: return 15
            case .thirty: return 30
            case .fortyFive: return 45
            case .sixty: return 60
            case .endOfChapter: return nil
            }
        }
    }

    private var sleepTimer: Timer?
    private var sleepTimerEndOfChapter: Bool = false
    private var volumeBeforeSleep: Float = 1.0

    // MARK: - Private

    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var currentBook: Book?
    private var saveTimer: Timer?
    private var currentCredential: DriveCredential?

    // Available playback speeds
    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // MARK: - Lifecycle

    init() {
        // Restore saved playback speed
        let savedRate = UserDefaults.standard.float(forKey: "playbackRate")
        if savedRate > 0 {
            playbackRate = savedRate
        }
        setupAudioSession()
        setupRemoteCommands()
    }

    // MARK: - Audio Session (iOS-specific)

    /// Configures the audio session for background playback
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }

    // MARK: - Playback Controls

    /// Loads and plays a book from its saved position.
    /// If the book is downloaded, plays from local storage.
    /// If not downloaded, streams from Google Drive using the provided credential.
    func play(book: Book, credential: DriveCredential? = nil) {
        // Clear any previous error and show loading state
        playbackError = nil
        isLoading = true
        currentCredential = credential

        // If switching books, save the current one's position first and reset retry flag
        if currentBook == nil || currentBook?.objectID != book.objectID {
            if currentBook != nil {
                savePosition()
            }
            hasRetriedToken = false
        }

        currentBook = book

        // Don't observe player item status yet — we handle initial load failures
        // via try/catch below. KVO is set up AFTER successful load to catch
        // mid-playback failures (like token expiry during streaming).
        statusObservation?.invalidate()

        // Load duration then start playback once the asset is ready
        let savedPosition = book.playbackPosition
        let rate = playbackRate
        let wasLocal = book.isDownloaded
        Task {
            // Determine the playback source (inside Task so we can await URL resolution)
            let playerItem: AVPlayerItem

            if book.isDownloaded, let localURL = book.localFileURL,
               FileManager.default.fileExists(atPath: localURL.path) {
                // Play from local file
                playerItem = AVPlayerItem(url: localURL)
            } else if let fileId = book.driveFileId, let credential {
                // Stream from Google Drive — resolve redirect first so AVURLAsset
                // doesn't need auth headers (it strips them on cross-origin redirects)
                let asset = await MetadataExtractor.remoteAsset(driveFileId: fileId, credential: credential)
                playerItem = AVPlayerItem(asset: asset)
            } else {
                self.isLoading = false
                self.playbackError = "Cannot play this file. Try downloading it first."
                return
            }

            if self.player == nil {
                self.player = AVPlayer(playerItem: playerItem)
            } else {
                self.player?.replaceCurrentItem(with: playerItem)
            }

            // Observe time updates
            self.setupTimeObserver()

            var activeItem = playerItem

            do {
                let loadedDuration = try await activeItem.asset.load(.duration)
                let secs = CMTimeGetSeconds(loadedDuration)
                if secs.isFinite {
                    self.duration = secs
                }
            } catch {
                // If this was a local file that failed, it may be corrupt (e.g. a JSON error
                // response saved by a broken download). Clear the download flag, delete the
                // corrupt file, and fall back to streaming.
                if wasLocal, let localURL = book.localFileURL {
                    book.isDownloaded = false
                    PersistenceController.shared.save()
                    try? FileManager.default.removeItem(at: localURL)

                    // Retry as streaming if we have a credential
                    if let fileId = book.driveFileId, let credential = self.currentCredential {
                        let asset = await MetadataExtractor.remoteAsset(driveFileId: fileId, credential: credential)
                        let streamItem = AVPlayerItem(asset: asset)
                        self.player?.replaceCurrentItem(with: streamItem)
                        self.hasRetriedToken = true
                        activeItem = streamItem

                        do {
                            let streamDuration = try await streamItem.asset.load(.duration)
                            let streamSecs = CMTimeGetSeconds(streamDuration)
                            if streamSecs.isFinite {
                                self.duration = streamSecs
                            }
                        } catch {
                            self.isLoading = false
                            self.playbackError = Self.friendlyPlaybackError(error)
                            return
                        }
                        // Continue to seek + play below
                    } else {
                        self.isLoading = false
                        self.playbackError = "Downloaded file was corrupt. Sign out and back in, then try again."
                        return
                    }
                } else {
                    self.isLoading = false
                    self.playbackError = Self.friendlyPlaybackError(error)
                    return
                }
            }

            // Asset loaded successfully — now observe for mid-playback failures
            self.observePlayerItemStatus(activeItem)

            // Seek to saved position if needed
            if savedPosition > 0 {
                let seekTime = CMTime(seconds: savedPosition, preferredTimescale: 600)
                await self.player?.seek(to: seekTime)
            }

            // Start playback
            self.player?.play()
            if rate != 1.0 {
                self.player?.rate = rate
            }

            // Set state after playback actually starts
            self.isLoading = false
            self.isPlaying = true
            self.startSaveTimer()
            self.updateNowPlayingInfo()
            book.lastPlayedDate = Date()
            PersistenceController.shared.save()
        }
    }

    /// Toggles play/pause
    func togglePlayPause() {
        guard let player = player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            savePosition()
        } else {
            player.rate = playbackRate
            isPlaying = true
            startSaveTimer()
        }
        updateNowPlayingInfo()
    }

    /// Pauses playback and saves position
    func pause() {
        player?.pause()
        isPlaying = false
        savePosition()
        updateNowPlayingInfo()
    }

    /// Default skip interval — 10s for video, 30s for audio
    var skipInterval: Double { currentBookIsVideo ? 10 : 30 }

    /// Skips forward by the given number of seconds (defaults to skipInterval)
    func skipForward(_ seconds: Double? = nil) {
        guard let player = player else { return }
        let amount = seconds ?? skipInterval
        let target = min(currentTime + amount, duration)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time)
        updateNowPlayingInfo()
    }

    /// Skips backward by the given number of seconds (defaults to skipInterval)
    func skipBackward(_ seconds: Double? = nil) {
        guard let player = player else { return }
        let amount = seconds ?? skipInterval
        let target = max(currentTime - amount, 0)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time)
        updateNowPlayingInfo()
    }

    /// Seeks to a specific time
    func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time)
        updateNowPlayingInfo()
    }

    /// Sets the playback speed
    func setSpeed(_ speed: Float) {
        playbackRate = speed
        UserDefaults.standard.set(speed, forKey: "playbackRate")
        if isPlaying {
            player?.rate = speed
        }
        updateNowPlayingInfo()
    }

    /// Saves current position and stops playback
    func stop() {
        savePosition()
        player?.pause()
        isPlaying = false
        removeTimeObserver()
        saveTimer?.invalidate()
    }

    /// When true, position is not saved to Core Data (used by discover mode)
    var skipPositionSave: Bool = false

    /// True if the currently loaded book is a video file
    var currentBookIsVideo: Bool { currentBook?.isVideo ?? false }

    /// The AVPlayer instance — used by VideoLayerView to render video frames
    var avPlayer: AVPlayer? { player }

    // MARK: - Sleep Timer Controls

    /// Sets a sleep timer for the given option
    func setSleepTimer(option: SleepTimerOption) {
        cancelSleepTimer()

        if option == .endOfChapter {
            sleepTimerEndOfChapter = true
            isSleepTimerActive = true
            sleepTimerRemaining = 0  // shows "End of Chapter" in UI
            return
        }

        guard let minutes = option.minutes else { return }
        sleepTimerRemaining = TimeInterval(minutes * 60)
        isSleepTimerActive = true
        volumeBeforeSleep = player?.volume ?? 1.0

        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.sleepTimerRemaining -= 1
                if self.sleepTimerRemaining <= 3 && self.sleepTimerRemaining > 0 {
                    // Fade volume during last 3 seconds
                    let fraction = Float(self.sleepTimerRemaining / 3.0)
                    self.player?.volume = self.volumeBeforeSleep * fraction
                }
                if self.sleepTimerRemaining <= 0 {
                    self.fireSleepTimer()
                }
            }
        }
    }

    /// Cancels the active sleep timer
    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndOfChapter = false
        isSleepTimerActive = false
        sleepTimerRemaining = 0
        // Restore volume if it was faded
        player?.volume = volumeBeforeSleep
    }

    /// Called by PlayerViewModel when a chapter boundary is crossed while "End of Chapter" is active
    func checkEndOfChapterSleep(oldChapterIndex: Int, newChapterIndex: Int) {
        guard sleepTimerEndOfChapter, newChapterIndex != oldChapterIndex else { return }
        fireSleepTimer()
    }

    /// Fades volume and pauses
    private func fireSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil

        // Fade out over a brief period then pause
        let savedVolume = volumeBeforeSleep
        player?.volume = 0
        pause()
        player?.volume = savedVolume

        isSleepTimerActive = false
        sleepTimerRemaining = 0
        sleepTimerEndOfChapter = false
    }

    // MARK: - Position Persistence

    /// Saves the current playback position to Core Data (skipped in discover mode)
    func savePosition() {
        guard let book = currentBook, !skipPositionSave else { return }
        book.playbackPosition = currentTime
        PersistenceController.shared.save()
    }

    /// Produces a user-friendly error message for playback failures.
    /// Detects permission issues (common with shared Drive folders) and gives
    /// actionable guidance instead of raw error text.
    private static func friendlyPlaybackError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("403") || desc.contains("quota") {
            return "Download quota exceeded for this file. Try again in a few hours, or copy the file to your own Google Drive."
        }
        if desc.contains("permission") || desc.contains("access") {
            return "Google Drive denied access to this file. The folder owner may have restricted downloads."
        }
        return "Could not play: \(error.localizedDescription)"
    }

    // MARK: - Auto-Complete

    /// Checks if the book should be marked as completed (>= 95% listened)
    private func checkAutoComplete() {
        guard let book = currentBook, duration > 0 else { return }
        let progress = currentTime / duration
        if progress >= 0.95 && !book.isCompleted {
            book.isCompleted = true
            PersistenceController.shared.save()
        }
    }

    // MARK: - Player Item Status

    private var hasRetriedToken = false

    private func observePlayerItemStatus(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        // Don't reset hasRetriedToken here — it's reset only when a different book
        // starts playing (in play()). Resetting here caused an infinite retry loop:
        // play() → observe → fail → retry → play() → observe (reset) → fail → retry → ...
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                if item.status == .failed, let error = item.error {
                    // If streaming failed, it might be a token expiry — retry once
                    if let book = self.currentBook, book.willStream, !self.hasRetriedToken {
                        self.hasRetriedToken = true
                        self.tokenExpiryRetryHandler?()
                    } else {
                        self.playbackError = Self.friendlyPlaybackError(error)
                        self.isPlaying = false
                    }
                }
            }
        }
    }

    /// Handler called when a streaming playback fails (likely token expiry).
    /// Set by PlayerViewModel to retry with a fresh token.
    var tokenExpiryRetryHandler: (() -> Void)?

    // MARK: - Time Observation

    private func setupTimeObserver() {
        removeTimeObserver()

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                Task { @MainActor in
                    self.currentTime = seconds
                    self.checkAutoComplete()
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    // MARK: - Periodic Save

    private func startSaveTimer() {
        saveTimer?.invalidate()
        // Save every 10 seconds on iOS (more frequent than macOS's 30s due to possible process termination)
        saveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.savePosition()
            }
        }
    }

    // MARK: - Remote Commands & Now Playing

    /// Sets up lock screen / Control Center remote commands
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                self?.seek(to: posEvent.positionTime)
            }
            return .success
        }
    }

    /// Updates the lock screen / Control Center Now Playing info
    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentBook?.displayTitle ?? "Audiobook"
        info[MPMediaItemPropertyArtist] = currentBook?.displayAuthor ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        // Set cover art for lock screen — always provide artwork, fall back to placeholder
        let coverImage = currentBook?.coverImage ?? Book.placeholderCover
        let artwork = MPMediaItemArtwork(boundsSize: coverImage.size) { _ in coverImage }
        info[MPMediaItemPropertyArtwork] = artwork

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
