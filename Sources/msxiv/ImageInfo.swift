import Foundation
import CoreGraphics
import ImageIO

struct ImageInfo {
    static func format(index: Int, total: Int, filename: String, width: Int, height: Int, zoom: CGFloat, fileSize: UInt64?, dateTaken: String?, slideshow: String? = nil) -> String {
        let zoomPct = Int(zoom * 100)
        var s = "[\(index + 1)/\(total)] \(filename) (\(width)x\(height)) \(zoomPct)%"
        if let size = fileSize { s += " \(humanSize(size))" }
        if let d = dateTaken { s += " \(d)" }
        if let sl = slideshow { s += "  \(sl)" }
        return s
    }

    static func humanSize(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes)B" }
        if b < 1024 * 1024 { return String(format: "%.1fKB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1fMB", b / (1024 * 1024)) }
        return String(format: "%.2fGB", b / (1024 * 1024 * 1024))
    }

    /// EXIF DateTimeOriginal ("2026:09:23 22:14:52") -> "2026-09-23",
    /// falling back to the file modification date.
    static func photoDate(for url: URL) -> String? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let day = raw.split(separator: " ").first.map(String.init) ?? raw
            return day.replacingOccurrences(of: ":", with: "-")
        }
        if let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: mod)
        }
        return nil
    }

    static func fileSize(for url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
    }
}
