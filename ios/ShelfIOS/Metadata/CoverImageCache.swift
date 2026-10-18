import UIKit
import ImageIO
import CoreData

/// Decoded, downsampled cover images keyed by book and size.
///
/// List rows read a cover on every render. Decoding the stored JPEG each time
/// (600x600 for a 56 pt thumbnail) was the main source of scroll jank, so covers
/// are decoded once per size and kept in an `NSCache` that the system can purge
/// under memory pressure. Entries self-invalidate when the stored cover changes.
final class CoverImageCache {
    static let shared = CoverImageCache()

    enum Size: Int {
        /// Rows, the mini player, and genre collages
        case thumbnail = 256
        /// Grid cards and the full player
        case full = 1200
    }

    private final class Entry {
        let byteCount: Int
        let image: UIImage
        init(byteCount: Int, image: UIImage) {
            self.byteCount = byteCount
            self.image = image
        }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private init() {}

    /// Returns the decoded cover for a book, or nil when the book has none.
    func image(for book: Book, size: Size) -> UIImage? {
        guard let data = book.coverArtData, !data.isEmpty else { return nil }
        let key = "\(book.objectID.uriRepresentation().absoluteString)#\(size.rawValue)" as NSString

        if let entry = cache.object(forKey: key), entry.byteCount == data.count {
            return entry.image
        }

        guard let image = Self.decode(data, maxPixelSize: size.rawValue) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(Entry(byteCount: data.count, image: image), forKey: key, cost: cost)
        return image
    }

    /// Drops every cached image. Call after bulk cover changes.
    func removeAll() {
        cache.removeAllObjects()
    }

    /// Decodes image data straight to a bitmap no larger than `maxPixelSize` on its longest side.
    static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
