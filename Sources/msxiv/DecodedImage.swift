import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// A decoded image plus everything needed to draw it *without* ever
/// allocating a full-size RGBA buffer.
///
/// Why this exists: loading a 40 MB / 100-megapixel photo the naive way
/// (decode to a full CGImage, then blit that whole bitmap into the view on
/// every redraw) costs hundreds of megabytes per image and tens of
/// milliseconds per frame — which is exactly why navigating between large
/// files felt sluggish. Instead we:
///
///   1. decode at most once, at display resolution (`kCGImageSourceThumbnailMaxPixelSize`),
///      so memory stays bounded no matter how huge the source file is;
///   2. hand `ImageView` a lazily-backed `NSImage` whose drawing closure
///      asks CoreGraphics to sample only the dirty rect of the source
///      image — panning/zooming never touches pixels outside the visible
///      area, and there is no intermediate full-resolution copy;
///   3. keep the raw `CGImage` around for window sizing / fit math.
struct DecodedImage {
    /// The decoded bitmap (possibly downsampled to `capPixels`), EXIF-oriented.
    let cgImage: CGImage
    /// Lazily-drawn NSImage wrapping the same pixels — the actual draw path.
    let nsImage: NSImage
    /// True when `cgImage` is smaller than the file's native pixel size,
    /// i.e. zooming past 100% cannot show more detail than what we hold.
    let downsampled: Bool
    /// Native pixel dimensions straight from the file header (no decode).
    let nativeWidth: Int
    let nativeHeight: Int
}

enum ImageDecoder {
    /// Decode an image for display.
    ///
    /// - Parameter capPixels: maximum long-edge in pixels. The decoder uses
    ///   ImageIO's thumbnail machinery as a *downsampler*: JPEG decodes at
    ///   DCT scale (1/2, 1/4, 1/8) natively — 4-8x faster and ~16x less
    ///   memory than a full decode — and HEIC/PNG/TIFF/WebP get the same
    ///   bounded result through accelerated tiled decoding. Files already
    ///   smaller than the cap are returned at full native resolution.
    ///
    /// Camera RAW files take a dedicated fast lane (see `RawSupport`): the
    /// embedded JPEG preview is read straight out of the container instead of
    /// demosaicing Bayer sensor data, and ImageIO gets an explicit type hint
    /// so every RAW flavor Apple ships a codec for actually decodes.
    static func decodeForDisplay(from url: URL, capPixels: Int) -> DecodedImage? {
        var sourceOptions: [CFString: Any] = [:]
        let isRaw = RawSupport.isRawFile(at: url)
        if isRaw, let hint = RawSupport.typeHint(for: url) {
            sourceOptions[kCGImageSourceTypeIdentifierHint] = hint
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }

        // Header-only property read: gives us native dimensions + EXIF
        // orientation without decoding a single pixel.
        var nativeW = 0, nativeH = 0, orientation = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            nativeW = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            nativeH = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: capPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true, // fall back to real downsampling when no embedded thumb fits
            kCGImageSourceCreateThumbnailWithTransform: false,  // we orient ourselves, below
            kCGImageSourceShouldCacheImmediately: true,         // decode now, off the main thread
        ]
        // RAW fast lane: sniff the container's embedded JPEG preview first.
        // Reading a few hundred KB of pre-baked pixels beats letting ImageIO
        // demosaic tens of megabytes of Bayer data on every navigation key.
        var rawPreviewUsed = false
        var raw: CGImage?
        if isRaw, let preview = RawSupport.decodeEmbeddedPreview(from: url, capPixels: capPixels) {
            raw = preview
            rawPreviewUsed = true
        }
        if raw == nil {
            raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? ImageLoader.load(from: url) // last resort: exotic format with no readable dims
        }
        guard let raw = raw else { return nil }

        // EXIF orientation: applying it to the *downsampled* bitmap is cheap
        // (a few megapixels worst case instead of dozens).
        let oriented: CGImage
        if orientation != 1, let t = ImageLoader.applyingExifOrientation(orientation, to: raw) {
            oriented = t
        } else {
            oriented = raw
        }

        // Swap-aware native dims so they match the oriented output.
        let swapWH = (5...8).contains(orientation)
        var outNativeW = swapWH ? nativeH : nativeW
        var outNativeH = swapWH ? nativeW : nativeH

        // A RAW container's TIFF header can report the *sensor* dimensions
        // while the embedded preview we actually decoded is smaller (or even
        // rotated differently). Trust the preview's own pixels for zoom math
        // so "100%" matches what is on screen.
        if rawPreviewUsed {
            outNativeW = oriented.width
            outNativeH = oriented.height
        }

        let downsampled = oriented.width < max(1, outNativeW) || oriented.height < max(1, outNativeH)

        return DecodedImage(cgImage: oriented,
                            nsImage: deferredNSImage(from: oriented),
                            downsampled: downsampled,
                            nativeWidth: outNativeW > 0 ? outNativeW : oriented.width,
                            nativeHeight: outNativeH > 0 ? outNativeH : oriented.height)
    }

    /// Wrap a CGImage in an NSImage whose `draw` handler samples only the
    /// region AppKit is actually asking to be painted (the dirty rect).
    /// No full-size intermediate bitmap is ever created, and the closure
    /// captures nothing but the small image itself.
    private static func deferredNSImage(from image: CGImage) -> NSImage {
        let size = NSSize(width: image.width, height: image.height)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Setting the clip is what makes this lazy: CoreGraphics samples
            // only the pixels inside the current clip (the dirty rect), never
            // the whole bitmap. There is no "draw only rect" API — clipping
            // then drawing is exactly how that optimization is expressed.
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
            return true
        }
        img.accessibilityDescription = "msxiv"
        return img
    }
}
