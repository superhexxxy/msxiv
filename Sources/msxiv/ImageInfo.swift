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
        if let mod = ImageInfo.modDate(of: url) {
            return ImageInfo.cachedDateString(from: mod)
        }
        return nil
    }

    /// Cached DateFormatter (creating one costs ~50µs; the old code built a
    /// fresh instance on every call) + memoized result per modification time.
    private static let dateCacheLock = NSLock()
    private static var dateFormatter: DateFormatter?
    private static var dateStringCache: [TimeInterval: String] = [:]

    private static func cachedDateString(from date: Date) -> String {
        let key = date.timeIntervalSince1970
        dateCacheLock.lock()
        defer { dateCacheLock.unlock() }
        if let s = dateStringCache[key] { return s }
        if dateFormatter == nil {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            dateFormatter = f
        }
        let s = dateFormatter!.string(from: date)
        if dateStringCache.count > 2048 { dateStringCache.removeAll() }
        dateStringCache[key] = s
        return s
    }

    /// Cheap mtime lookup via raw stat instead of attributesOfItem.
    static func modDate(of url: URL) -> Date? {
        var s = stat()
        guard stat(url.path, &s) == 0 else { return nil }
        #if os(macOS)
        return Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec)
                    + TimeInterval(s.st_mtimespec.tv_nsec) * 1e-9)
        #else
        return Date(timeIntervalSince1970: TimeInterval(s.st_mtim.tv_sec)
                    + TimeInterval(s.st_mtim.tv_nsec) * 1e-9)
        #endif
    }

    static func fileSize(for url: URL) -> UInt64? {
        var s = stat()
        guard stat(url.path, &s) == 0 else { return nil }
        return UInt64(max(0, s.st_size))
    }
}
