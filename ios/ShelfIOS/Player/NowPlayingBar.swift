import SwiftUI

/// Mini player bar shown at the bottom of the library when media is playing
struct NowPlayingBar: View {
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var audioService: AudioPlayerService

    var body: some View {
        if let book = playerVM.currentBook {
            VStack(spacing: 0) {
                // Progress line at top
                GeometryReader { geo in
                    Rectangle()
                        .fill(AppColors.progressFill)
                        .frame(width: geo.size.width * (audioService.duration > 0 ? audioService.currentTime / audioService.duration : 0))
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    // Cover art
                    Image(uiImage: book.thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Title
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.displayTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(book.displayAuthor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Play/pause
                    if audioService.isLoading {
                        ProgressView()
                            .frame(width: 44, height: 44)
                    } else {
                        Button {
                            Haptics.light()
                            audioService.togglePlayPause()
                        } label: {
                            Image(systemName: audioService.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                        }
                    }

                    // Skip forward — 10s for video, 30s for audio
                    Button {
                        Haptics.light()
                        audioService.skipForward()
                    } label: {
                        Image(systemName: audioService.currentBookIsVideo ? "goforward.10" : "goforward.30")
                            .font(.body)
                            .frame(width: 36, height: 44)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture {
                playerVM.showFullPlayer = true
            }
        }
    }
}
