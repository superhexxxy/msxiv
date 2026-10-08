import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

class ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private let cacheDir: URL
    private let queue = DispatchQueue(label: "msxiv.thumbcache", qos: .userInitiated)
    
    // In-memory LRU-ish cache for currently visible thumbnails
    private var memoryCache: [String: CGImage] = [:]
    private let maxMemoryCache = 200
    
    private init() {
        cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/msxiv/thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    
    /// Generate a stable cache key from file path + modification date
    func cacheKey(for url: URL) -> String {
        let modDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        let input = "\(url.path)|\(modDate)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Try memory cache first, then disk cache
    func cachedThumbnail(for url: URL) -> CGImage? {
        let key = cacheKey(for: url)
        
        // Memory hit
        if let img = memoryCache[key] { return img }
        
        // Disk hit
        let diskURL = cacheDir.appendingPathComponent("\(key).png")
        if let source = CGImageSourceCreateWithURL(diskURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            memoryCache[key] = img
            trimMemoryCache()
            return img
        }
        
        return nil
    }
    
    /// Generate thumbnail on background queue, save to disk + memory, then callback on main
    func generateAndCache(for url: URL, maxSize: Int, completion: @escaping (CGImage?) -> Void) {
        let key = cacheKey(for: url)
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Generate
            guard let thumb = ThumbnailGenerator.generate(from: url, maxSize: maxSize) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            // Save to disk
            let diskURL = self.cacheDir.appendingPathComponent("\(key).png")
            if let dest = CGImageDestinationCreateWithURL(diskURL as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, thumb, nil)
                CGImageDestinationFinalize(dest)
            }
            
            // Save to memory
            DispatchQueue.main.async {
                self.memoryCache[key] = thumb
                self.trimMemoryCache()
                completion(thumb)
            }
        }
    }

    /// Drop memory + disk cache entries for a deleted file.
    func remove(for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("\(key).png"))
    }
    
    private func trimMemoryCache() {
        if memoryCache.count > maxMemoryCache {
            // Simple trim: remove first N entries (not true LRU but good enough)
            let excess = memoryCache.count - maxMemoryCache
            for key in memoryCache.keys.prefix(excess) {
                memoryCache.removeValue(forKey: key)
            }
        }
    }
}
