import Foundation
import CoreGraphics
import ImageIO

struct ThumbnailGenerator {
    /// Generate a downsampled thumbnail. Never loads the full image.
    static func generate(from url: URL, maxSize: Int) -> CGImage? {
        // RAW magic: camera RAW containers need an explicit UTI hint before
        // ImageIO will treat their bytes as images at all.
        var sourceOptions: [CFString: Any] = [:]
        let isRaw = RawSupport.isRawFile(at: url)
        if isRaw, let hint = RawSupport.typeHint(for: url) {
            sourceOptions[kCGImageSourceTypeIdentifierHint] = hint
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }

        // RAW fast lane: for grid mode over a folder of 40MB RAW files, the
        // embedded JPEG preview is *exactly* what we want — reading it costs
        // milliseconds instead of a Bayer demosaic per cell. If sniffing
        // fails we fall through to ImageIO's own pipeline below.
        if isRaw, let preview = RawSupport.decodeEmbeddedPreview(from: url, capPixels: maxSize) {
            return orientIfNeeded(preview, source: source)
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true // auto-applies EXIF rotation
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The embedded-preview path bypasses `kCGImageSourceCreateThumbnailWithTransform`,
    /// so apply EXIF orientation manually (previews are usually already
    /// upright; orientation 1 makes this a no-op).
    private static func orientIfNeeded(_ image: CGImage, source: CGImageSource) -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? Int, o != 1,
              let t = ImageLoader.applyingExifOrientation(o, to: image) else { return image }
        return t
    }
}
