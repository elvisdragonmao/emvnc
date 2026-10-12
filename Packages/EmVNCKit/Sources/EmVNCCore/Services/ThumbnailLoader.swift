import CoreGraphics
import Foundation
import ImageIO

/// Thread-safe, cached, downsampled image loading for screenshot thumbnails. Decoding a 4K PNG takes tens
/// of milliseconds, so cards load thumbnails off the main thread through this.
public final class ThumbnailLoader: @unchecked Sendable {
    public static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 300
    }

    public func image(at url: URL, maxPixelSize: Int) -> CGImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        cache.setObject(image, forKey: key)

        return image
    }

    public func load(at url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .utility) { [self] in
            image(at: url, maxPixelSize: maxPixelSize)
        }.value
    }

    public func removeAll() {
        cache.removeAllObjects()
    }
}
