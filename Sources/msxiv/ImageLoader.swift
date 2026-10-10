import Foundation
import ImageIO
import CoreGraphics

/// Shared bitmap context. NOTE: never reuse a source image's own
/// `colorSpace`/`bitmapInfo` — combos like ARGB-nonpremultiplied make
/// CGContext creation return nil. Normalized DeviceRGB/RGBA always works
/// (drawing converts color spaces automatically).
func msxivBitmapContext(width: Int, height: Int) -> CGContext? {
    CGContext(data: nil, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
}

struct ImageLoader {
    static func load(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // Options for fast, hardware-accelerated decoding
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true, // Decode now, not lazily
            kCGImageSourceShouldAllowFloat: true
        ]

        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        // Apply EXIF orientation (kCGImageSourceTransformOrientation does not exist;
        // thumbnails handle it via kCGImageSourceCreateThumbnailWithTransform,
        // full images need a manual transform).
        let orientation = exifOrientation(of: source)
        guard orientation != 1 else { return raw }
        return applyingExifOrientation(orientation, to: raw)
    }

    private static func exifOrientation(of source: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? Int else { return 1 }
        return o
    }

    /// Shared with ImageDecoder: EXIF-orienting a *downsampled* bitmap is
    /// far cheaper than orienting the full-resolution decode.
    static func applyingExifOrientation(_ orientation: Int, to image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        // Orientations 5-8 swap width/height
        let swapWH = (5...8).contains(orientation)
        let outW = swapWH ? h : w
        let outH = swapWH ? w : h

        guard let ctx = msxivBitmapContext(width: outW, height: outH) else { return image }

        var t = CGAffineTransform.identity
        // Note: CGContext origin is bottom-left; map EXIF orientation accordingly.
        switch orientation {
        case 2: // flip horizontal
            t = t.translatedBy(x: CGFloat(outW), y: 0).scaledBy(x: -1, y: 1)
        case 3: // rotate 180
            t = t.translatedBy(x: CGFloat(outW), y: CGFloat(outH)).rotated(by: .pi)
        case 4: // flip vertical
            t = t.translatedBy(x: 0, y: CGFloat(outH)).scaledBy(x: 1, y: -1)
        case 5: // transpose
            t = t.translatedBy(x: CGFloat(outW), y: CGFloat(outH)).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 6: // rotate 90 CW
            t = t.translatedBy(x: CGFloat(outW), y: 0).rotated(by: .pi / 2)
        case 7: // transverse
            t = t.translatedBy(x: 0, y: 0).rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
        case 8: // rotate 270 CW
            t = t.translatedBy(x: 0, y: CGFloat(outH)).rotated(by: -.pi / 2)
        default:
            return image
        }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
