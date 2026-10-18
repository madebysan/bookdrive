import Foundation

/// Fetches cover art using a three-pass waterfall:
/// 1. iTunes Search API (audiobook-specific, best for audiobooks)
/// 2. Google Books API (print editions, good academic coverage)
/// 3. Open Library (last resort fallback)
/// No authentication required — all three APIs are free and public.
enum CoverArtService {

    // MARK: - Public API

    /// Searches for a cover image matching the given title and author.
    /// Tries iTunes → Google Books → Open Library in order, returning the first match.
    /// Returns image data on success, nil if all three fail.
    static func fetchCover(title: String, author: String?) async -> Data? {
        let cleanedTitle = cleanTitle(title)
        // Use first author name only (before comma) to avoid narrator contamination
        let primaryAuthor = extractPrimaryAuthor(from: author)

        // Pass 1: iTunes Search API (audiobook-specific)
        if let data = await fetchFromiTunes(title: cleanedTitle, author: primaryAuthor) {
            print("  [iTunes] Found cover")
            return data
        }

        // Pass 2: Google Books API (print editions)
        if let data = await fetchFromGoogleBooks(title: cleanedTitle, author: primaryAuthor) {
            print("  [Google Books] Found cover")
            return data
        }

        // Pass 3: Open Library (last resort)
        if let data = await fetchFromOpenLibrary(title: cleanedTitle, author: primaryAuthor) {
            print("  [Open Library] Found cover")
            return data
        }

        return nil
    }

    // MARK: - Author Extraction

    /// Extracts the primary author from a combined "Author, Narrator" string.
    /// Audiobook metadata often lists both: "Bhikhu Parekh, Mark Ashby"
    /// where the first name is the author and the second is the narrator.
    private static func extractPrimaryAuthor(from author: String?) -> String? {
        guard let author = author, !author.isEmpty else { return nil }
        return author.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Title Cleaning

    /// Strips audiobook-specific suffixes that hurt search accuracy:
    /// "(Unabridged)", "(Abridged)", "[Audiobook]", "- Audiobook", etc.
    static func cleanTitle(_ title: String) -> String {
        var cleaned = title

        // Remove parenthesized/bracketed audiobook markers
        let patterns = [
            "\\(unabridged\\)",
            "\\(abridged\\)",
            "\\[audiobook\\]",
            "\\[unabridged\\]",
            "\\[abridged\\]",
            "\\(audiobook\\)",
            "-\\s*audiobook",
            ":\\s*audiobook",
            "\\s+audiobook$",
            // Edition markers that can confuse search
            "\\(\\d+\\w*\\s+edition\\)",
            "\\[\\d+\\w*\\s+edition\\]"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }

        // Trim whitespace and trailing punctuation left behind
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "- :"))

        return cleaned
    }

    // MARK: - iTunes Search API

    /// Searches iTunes for an audiobook matching the title + author and downloads its cover art.
    /// Uses the media=audiobook filter for precise audiobook matching.
    /// Including the author is critical — generic titles like "Gandhi" or "The Bible"
    /// return wrong books without it.
    private static func fetchFromiTunes(title: String, author: String?) async -> Data? {
        // Combine title + author for the search term
        var searchTerm = title
        if let author = author, !author.isEmpty {
            searchTerm += " \(author)"
        }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: searchTerm),
            URLQueryItem(name: "media", value: "audiobook"),
            URLQueryItem(name: "limit", value: "5")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Parse: { "resultCount": N, "results": [{ "artworkUrl100": "..." }] }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let results = json?["results"] as? [[String: Any]],
                  let firstResult = results.first,
                  let artworkURL = firstResult["artworkUrl100"] as? String else {
                return nil
            }

            // Upscale artwork URL: replace 100x100bb with 600x600bb for higher resolution
            let highResURL = artworkURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")

            return await downloadImage(from: highResURL)
        } catch {
            print("  [iTunes] Search failed for \"\(title)\": \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Google Books API

    /// Searches Google Books for the title and downloads its cover thumbnail.
    /// Uses the free tier (no API key, 100 requests/day limit).
    private static func fetchFromGoogleBooks(title: String, author: String?) async -> Data? {
        // Build query: use intitle for precision, optionally add inauthor
        var query = "intitle:\(title)"
        if let author = author, !author.isEmpty {
            query += "+inauthor:\(author)"
        }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "1")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Parse: { "items": [{ "volumeInfo": { "imageLinks": { "thumbnail": "..." } } }] }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let items = json?["items"] as? [[String: Any]],
                  let volumeInfo = items.first?["volumeInfo"] as? [String: Any],
                  let imageLinks = volumeInfo["imageLinks"] as? [String: Any],
                  let thumbnail = imageLinks["thumbnail"] as? String else {
                return nil
            }

            // Google returns http:// URLs — upgrade to https://
            // Also try to get a larger image by removing edge=curl and changing zoom
            var imageURL = thumbnail.replacingOccurrences(of: "http://", with: "https://")
            imageURL = imageURL.replacingOccurrences(of: "&edge=curl", with: "")
            imageURL = imageURL.replacingOccurrences(of: "zoom=1", with: "zoom=2")

            return await downloadImage(from: imageURL)
        } catch {
            print("  [Google Books] Search failed for \"\(title)\": \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Open Library

    /// Searches Open Library for a book and downloads its cover image.
    private static func fetchFromOpenLibrary(title: String, author: String?) async -> Data? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "cover_i")
        ]
        if let author = author, !author.isEmpty {
            queryItems.append(URLQueryItem(name: "author", value: author))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Parse: { "docs": [{ "cover_i": 12345 }] }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let docs = json?["docs"] as? [[String: Any]]
            guard let coverID = docs?.first?["cover_i"] as? Int else {
                return nil
            }

            // Download cover image (large size, ?default=false returns 404 instead of placeholder)
            return await downloadImage(from: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg?default=false")
        } catch {
            print("  [Open Library] Search failed for \"\(title)\": \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Shared Image Download

    /// Downloads an image from a URL. Returns nil on error or if the data is too small
    /// (likely a placeholder or error page rather than a real image).
    private static func downloadImage(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Sanity check: reject tiny responses (likely placeholders or error pages)
            guard data.count > 1000 else { return nil }

            return data
        } catch {
            return nil
        }
    }
}
