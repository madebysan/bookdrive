import Foundation
import AVFoundation
import UIKit

/// Holds extracted metadata from an audio file before saving to Core Data
struct AudiobookMetadata {
    var title: String?
    var author: String?
    var genre: String?
    var year: Int32 = 0
    var rating: Int16 = 0       // 0 = unrated, 20/40/60/80/100 = 1–5 stars (iTunes scale)
    var duration: Double = 0
    var coverArtData: Data?
    var hasChapters: Bool = false
}

/// Chapter info extracted from m4b/m4a files
struct ChapterInfo: Identifiable {
    let id = UUID()
    let title: String
    let startTime: Double
    let duration: Double
}

/// Extracts metadata from audio files using AVFoundation.
/// Supports both local files and remote Google Drive files via authenticated AVURLAsset.
enum MetadataExtractor {

    // MARK: - Public API

    /// Extracts metadata from a local file URL
    static func extract(from url: URL) async -> AudiobookMetadata {
        let asset = AVURLAsset(url: url)
        return await extract(from: asset)
    }

    /// Extracts metadata from a remote Google Drive file without downloading it.
    /// By default skips cover art extraction — cover art is fetched separately via API
    /// (iTunes/Google Books/Open Library) which is much faster than streaming binary data from Drive.
    /// Pass `skipCoverArt: false` to also extract embedded cover art (used as fallback when API has no results).
    static func extractRemote(driveFileId: String, credential: DriveCredential, skipCoverArt: Bool = true) async -> AudiobookMetadata {
        let asset = await remoteAsset(driveFileId: driveFileId, credential: credential)
        let result = await extract(from: asset, skipCoverArt: skipCoverArt)
        // Cancel any pending loads to free memory immediately
        asset.cancelLoading()
        return result
    }

    /// Extracts metadata with a timeout — returns nil if extraction takes too long
    static func extractWithTimeout(from url: URL, timeout: TimeInterval = 10) async -> AudiobookMetadata? {
        return await withTaskGroup(of: AudiobookMetadata?.self) { group in
            group.addTask {
                return await Self.extract(from: url)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    /// Extracts metadata remotely with a timeout — returns nil if extraction takes too long.
    /// Pass `skipCoverArt: false` to also extract embedded cover art (slower but catches embedded covers).
    static func extractRemoteWithTimeout(driveFileId: String, credential: DriveCredential, timeout: TimeInterval = 15, skipCoverArt: Bool = true) async -> AudiobookMetadata? {
        return await withTaskGroup(of: AudiobookMetadata?.self) { group in
            group.addTask {
                return await Self.extractRemote(driveFileId: driveFileId, credential: credential, skipCoverArt: skipCoverArt)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    /// Extracts chapter list from a local audio file
    static func extractChapters(from url: URL) async -> [ChapterInfo] {
        let asset = AVURLAsset(url: url)
        return await extractChapters(from: asset)
    }

    /// Extracts chapter list from a remote Google Drive file
    static func extractRemoteChapters(driveFileId: String, credential: DriveCredential) async -> [ChapterInfo] {
        let asset = await remoteAsset(driveFileId: driveFileId, credential: credential)
        return await extractChapters(from: asset)
    }

    /// Builds an asset for a Drive file. Resolves the signed redirect first so the asset
    /// needs no auth headers (AVURLAsset drops them on cross-origin redirects); falls
    /// back to the direct media URL, which carries the API key itself or gets a header.
    static func remoteAsset(driveFileId: String, credential: DriveCredential) async -> AVURLAsset {
        if let resolvedURL = await GoogleDriveService.resolveStreamURL(for: driveFileId, credential: credential) {
            return AVURLAsset(url: resolvedURL)
        }
        var options: [String: Any] = [:]
        if let headers = credential.assetHeaders {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        return AVURLAsset(url: credential.mediaURL(for: driveFileId), options: options)
    }

    // MARK: - Core Extraction (works with any AVURLAsset — local or remote)

    /// Extracts metadata from an AVURLAsset.
    ///
    /// Two-pass approach:
    /// 1. Common metadata — covers most files, uses AVFoundation's unified key space
    /// 2. Format-specific metadata — fills gaps using iTunes (M4B/M4A) and ID3 (MP3) keys
    ///
    /// Audiobooks often store the author in "album artist" (not "artist"), and cover art
    /// or rating in format-specific fields that don't map to common keys.
    static func extract(from asset: AVURLAsset, skipCoverArt: Bool = false) async -> AudiobookMetadata {
        var metadata = AudiobookMetadata()

        // Track what the common pass found so the format-specific pass knows where to fill gaps
        var commonArtist: String?

        // Load duration
        do {
            let duration = try await asset.load(.duration)
            metadata.duration = CMTimeGetSeconds(duration)
        } catch {
            print("Failed to load duration: \(error)")
        }

        // --- Pass 1: Common metadata ---
        do {
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                guard let key = item.commonKey else { continue }

                switch key {
                case .commonKeyTitle:
                    metadata.title = try? await item.load(.stringValue)

                case .commonKeyArtist:
                    // In audiobooks this is often the narrator, not the author.
                    // Store it but prefer album artist from pass 2.
                    commonArtist = try? await item.load(.stringValue)

                case .commonKeyAuthor, .commonKeyCreator:
                    // Explicit author field — trust it
                    if metadata.author == nil {
                        metadata.author = try? await item.load(.stringValue)
                    }

                case .commonKeyArtwork:
                    if !skipCoverArt, metadata.coverArtData == nil,
                       let data = try? await item.load(.dataValue) {
                        metadata.coverArtData = data
                    }

                case .commonKeyCreationDate:
                    if let dateStr = try? await item.load(.stringValue),
                       let yearInt = Int32(String(dateStr.prefix(4))) {
                        metadata.year = yearInt
                    }

                case .commonKeyAlbumName:
                    // Some single-file audiobooks put the book title in "album"
                    // and the track/chapter title in "title". Keep album as fallback.
                    if metadata.title == nil {
                        metadata.title = try? await item.load(.stringValue)
                    }

                default:
                    break
                }
            }
        } catch {
            print("Failed to load common metadata: \(error)")
        }

        // If no explicit author was found, fall back to the common artist
        if metadata.author == nil {
            metadata.author = commonArtist
        }

        // --- Pass 2: Format-specific metadata (iTunes / ID3) ---
        // Fills in anything the common pass missed, plus rating which has no common key.
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let items = try await asset.loadMetadata(for: format)
                for item in items {
                    guard let identifier = item.identifier else { continue }

                    // Author — "album artist" is the standard field for book author
                    if identifier == .iTunesMetadataAlbumArtist ||
                       identifier == .id3MetadataBand {
                        if let val = try? await item.load(.stringValue), !val.isEmpty {
                            // Album artist overrides whatever common pass found,
                            // because in audiobooks this is the actual author
                            metadata.author = val
                        }
                    }

                    // Title fallbacks
                    if metadata.title == nil {
                        if identifier == .iTunesMetadataSongName ||
                           identifier == .iTunesMetadataAlbum ||
                           identifier == .id3MetadataTitleDescription ||
                           identifier == .id3MetadataAlbumTitle {
                            if let val = try? await item.load(.stringValue), !val.isEmpty {
                                metadata.title = val
                            }
                        }
                    }

                    // Cover art fallbacks
                    if !skipCoverArt, metadata.coverArtData == nil {
                        if identifier == .iTunesMetadataCoverArt ||
                           identifier == .id3MetadataAttachedPicture {
                            if let data = try? await item.load(.dataValue), !data.isEmpty {
                                metadata.coverArtData = data
                            }
                        }
                    }

                    // Genre
                    if metadata.genre == nil {
                        if identifier == .iTunesMetadataUserGenre ||
                           identifier == .iTunesMetadataGenreID ||
                           identifier == .id3MetadataContentType {
                            if let val = try? await item.load(.stringValue), !val.isEmpty {
                                metadata.genre = val
                            }
                        }
                    }

                    // Year
                    if metadata.year == 0 {
                        if identifier == .iTunesMetadataReleaseDate ||
                           identifier == .id3MetadataYear ||
                           identifier == .id3MetadataDate ||
                           identifier == .id3MetadataRecordingTime {
                            if let val = try? await item.load(.stringValue),
                               let yearInt = Int32(String(val.prefix(4))) {
                                metadata.year = yearInt
                            }
                        }
                    }

                    // Rating (no predefined AVMetadataIdentifier constants)
                    if metadata.rating == 0 {
                        let keyStr = (item.key as? String) ?? ""
                        let keySpaceStr = item.keySpace?.rawValue ?? ""

                        if keyStr == "rtng" && keySpaceStr == AVMetadataKeySpace.iTunes.rawValue {
                            // iTunes M4B/M4A: "rtng" key, stored as integer 0–100
                            if let num = try? await item.load(.numberValue) {
                                metadata.rating = Int16(clamping: num.intValue)
                            } else if let str = try? await item.load(.stringValue),
                                      let val = Int16(str) {
                                metadata.rating = val
                            }
                        } else if keyStr == "POPM" && keySpaceStr == AVMetadataKeySpace.id3.rawValue {
                            // ID3 POPM: byte 0–255, convert to 0–100 (iTunes) scale
                            if let num = try? await item.load(.numberValue) {
                                let raw = num.intValue
                                let scaled: Int16
                                switch raw {
                                case 0:        scaled = 0
                                case 1...31:   scaled = 20
                                case 32...95:  scaled = 40
                                case 96...159: scaled = 60
                                case 160...223: scaled = 80
                                default:       scaled = 100
                                }
                                metadata.rating = scaled
                            }
                        }
                    }
                }
            }
        } catch {
            // Non-critical — format-specific fields are best-effort
        }

        // Check for chapters
        do {
            let chapterLocales = try await asset.load(.availableChapterLocales)
            if !chapterLocales.isEmpty {
                let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages:
                    chapterLocales.map { Locale.canonicalLanguageIdentifier(from: $0.identifier) })
                metadata.hasChapters = !groups.isEmpty
            }
        } catch {
            // Non-critical — chapters are optional
        }

        // If no embedded cover art, try generating a thumbnail from a video frame.
        // Works for video files; silently fails for audio-only (no video track).
        if metadata.coverArtData == nil {
            do {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)
                // Grab a frame at ~10% into the video (1-5s to avoid seeking deep into large remote files)
                let targetTime = CMTime(seconds: max(min(metadata.duration * 0.1, 5), 1), preferredTimescale: 600)
                let (cgImage, _) = try await generator.image(at: targetTime)
                let uiImage = UIImage(cgImage: cgImage)
                metadata.coverArtData = uiImage.jpegData(compressionQuality: 0.7)
            } catch {
                // No video track or generation failed — placeholder will be used
            }
        }

        return metadata
    }

    /// Extracts chapter list from an AVURLAsset
    static func extractChapters(from asset: AVURLAsset) async -> [ChapterInfo] {
        var chapters: [ChapterInfo] = []

        do {
            let chapterLocales = try await asset.load(.availableChapterLocales)
            guard !chapterLocales.isEmpty else { return [] }

            let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages:
                chapterLocales.map { Locale.canonicalLanguageIdentifier(from: $0.identifier) })

            for group in groups {
                let timeRange = group.timeRange
                let startSeconds = CMTimeGetSeconds(timeRange.start)
                let durationSeconds = CMTimeGetSeconds(timeRange.duration)

                var chapterTitle = "Chapter \(chapters.count + 1)"
                for item in group.items {
                    if item.commonKey == .commonKeyTitle,
                       let title = try? await item.load(.stringValue) {
                        chapterTitle = title
                        break
                    }
                }

                chapters.append(ChapterInfo(
                    title: chapterTitle,
                    startTime: startSeconds,
                    duration: durationSeconds
                ))
            }
        } catch {
            print("Failed to extract chapters: \(error)")
        }

        return chapters
    }

    // MARK: - Filename Parsing

    /// Parses common audiobook filename patterns to extract title and author.
    /// Used as a fallback when embedded metadata tags are missing.
    ///
    /// Patterns recognized:
    /// - "Author - Title.ext"
    /// - "Title (Author).ext"
    /// - Anything else → filename (without extension) as title
    static func parseFilename(_ filename: String) -> (title: String?, author: String?) {
        // Remove file extension
        let name: String
        if let dotIndex = filename.lastIndex(of: ".") {
            name = String(filename[filename.startIndex..<dotIndex])
        } else {
            name = filename
        }
        guard !name.isEmpty else { return (nil, nil) }

        // Pattern: "Author - Title"
        if let dashRange = name.range(of: " - ") {
            let author = String(name[name.startIndex..<dashRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let title = String(name[dashRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !author.isEmpty && !title.isEmpty {
                return (title: title, author: author)
            }
        }

        // Pattern: "Title (Author)"
        if let openParen = name.lastIndex(of: "("),
           let closeParen = name.lastIndex(of: ")"),
           openParen < closeParen {
            let title = String(name[name.startIndex..<openParen])
                .trimmingCharacters(in: .whitespaces)
            let author = String(name[name.index(after: openParen)..<closeParen])
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty && !author.isEmpty {
                return (title: title, author: author)
            }
        }

        // No pattern matched — use filename as title
        return (title: name, author: nil)
    }
}
