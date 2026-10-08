import Foundation
import ImageIO
import CoreGraphics

/// Disk writes: currently only rotation-save. Re-encodes in place
/// (JPEG q0.95, others native) via a temp file + atomic replace.
struct ImageSaver {
    /// Rotate the file on disk 90° CW `turns` times. Returns false on failure.
    static func rotateCW(_ url: URL, quarterTurns: Int) -> Bool {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return true }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return false }

        for _ in 0..<turns {
            guard let r = rotated90CW(img) else { return false }
            img = r
        }

        let uti = (CGImageSourceGetType(src) as String?) ?? "public.png"

        // Carry the original metadata (EXIF incl. DateTimeOriginal, GPS, ICC
        // profile, color info) through the re-encode so rotation-save doesn't
        // silently strip it. Orientation is baked into the pixels by the
        // rotation below, so the stale orientation tag must be reset to .1.
        var props: [CFString: Any] =
            (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyOrientation] = 1
        if uti == "public.jpeg" { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".msxiv-\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, uti as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    private static func rotated90CW(_ img: CGImage) -> CGImage? {
        guard let ctx = msxivBitmapContext(width: img.height, height: img.width) else { return nil }
        ctx.translateBy(x: CGFloat(img.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}
