import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cacheDir: URL
    /// Concurrent generation pool: large directories get their thumbnails
    /// decoded in parallel instead of serially on one queue.
    private let genQueue: DispatchQueue
    /// Cap on simultaneous generations so we don't thrash memory/CPU.
    private let genSemaphore: DispatchSemaphore
    /// Bounds concurrent synchronous disk reads (memory-cache misses).
    private let ioSemaphore = DispatchSemaphore(value: 4)

    // True LRU memory cache guarded by `lock`. Recency is tracked with an
    // intrusive doubly-linked list (O(1) touch/evict) plus a key→node map,
    // instead of an array whose search+remove was O(n) per hit.
    private let lock = NSLock()
    private final class LRUNode {
        let key: String
        var prev: LRUNode?
        var next: LRUNode?
        init(_ key: String) { self.key = key }
    }
    private var lruHead: LRUNode?               // oldest
    private var lruTail: LRUNode?               // newest
    private var lruNodes: [String: LRUNode] = [:]
    private var lruCount = 0
    private var memoryCache: [String: CGImage] = [:]
    private let maxMemoryCache = 512
    /// Negative cache: files that failed to decode are not retried every redraw.
    private var failedKeys: Set<String> = []
    /// In-flight request coalescing: duplicate requests piggyback on one generation.
    private var inflightKeys: Set<String> = []
    private var inflightWaiters: [String: [(CGImage?) -> Void]] = [:]

    /// Cache-key memo: avoids a stat + SHA-256 on every lookup. Entries are
    /// dropped whenever the file's mtime can change while msxiv is running
    /// (thumbnail regenerated after external edit, or file deleted).
    /// Bounded with FIFO eviction in small batches so we never pay for a
    /// full-table flush spike mid-scroll.
    private var keyMemo: [String: String] = [:]
    private var keyMemoInsertionOrder: [String] = []   // oldest first
    private let maxKeyMemo = 8192
    private let keyMemoEvictBatch = 1024

    private init() {
        cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/msxiv/thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        genQueue = DispatchQueue(label: "msxiv.thumbcache", qos: .userInitiated, attributes: .concurrent)
        genSemaphore = DispatchSemaphore(value: max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Generate a stable cache key from file path + modification date.
    /// Uses raw `stat` instead of the much slower FileManager.attributesOfItem,
    /// and hex-encodes via a nibble table instead of per-byte String(format:).
    func cacheKey(for url: URL) -> String {
        var modTime = "0"
        var info = stat()
        if stat(url.path, &info) == 0 {
            #if os(macOS)
            modTime = "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            #else
            modTime = "\(info.st_mtim.tv_sec).\(info.st_mtim.tv_nsec)"
            #endif
        }
        // Memoize by path+mtime (never path alone: an edited file must map
        // to a fresh key, otherwise stale thumbnails stick around forever).
        let memoKey = "\(url.path)|\(modTime)"
        if let memo = keyMemo[memoKey] { return memo }

        let digest = SHA256.hash(data: Data(memoKey.utf8))
        var hex = ""
        hex.reserveCapacity(SHA256.byteCount * 2)
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        for byte in digest {
            hex.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
            hex.append(Character(UnicodeScalar(digits[Int(byte & 0xf)])))
        }
        if keyMemo.count >= maxKeyMemo { evictKeyMemoBatch() }
        keyMemo[memoKey] = hex
        keyMemoInsertionOrder.append(memoKey)
        return hex
    }

    /// Evict a bounded FIFO batch of memo entries instead of flushing the
    /// whole table, so eviction cost is amortized and never spikes.
    private func evictKeyMemoBatch() {
        let removeCount = min(keyMemoEvictBatch, keyMemoInsertionOrder.count)
        guard removeCount > 0 else { keyMemo.removeAll(); return }
        for old in keyMemoInsertionOrder.prefix(removeCount) {
            keyMemo.removeValue(forKey: old)
        }
        keyMemoInsertionOrder.removeFirst(removeCount)
    }

    /// Try memory cache first, then disk cache.
    func cachedThumbnail(for url: URL) -> CGImage? {
        let key = cacheKey(for: url)

        lock.lock()
        if let img = memoryCache[key] {
            touchLRU(key)
            lock.unlock()
            return img
        }
        lock.unlock()

        // Disk hit. Thumbnail-sized PNGs decode quickly; keep it synchronous
        // (instant display, no flicker) but bound concurrent disk reads.
        ioSemaphore.wait()
        defer { ioSemaphore.signal() }
        let diskURL = cacheDir.appendingPathComponent("\(key).png")
        if let source = CGImageSourceCreateWithURL(diskURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            insertMemory(key: key, image: img)
            return img
        }
        return nil
    }

    /// Generate thumbnail on the concurrent background pool, save to disk +
    /// memory, then callback on main. Duplicate requests for the same file
    /// are coalesced into a single generation.
    ///
    /// The semaphore wait happens on the background queue, never on the
    /// caller's thread, so calling this from the main thread can never stall
    /// the UI even when the generation pool is saturated.
    func generateAndCache(for url: URL, maxSize: Int, completion: @escaping (CGImage?) -> Void) {
        let key = cacheKey(for: url)

        lock.lock()
        if failedKeys.contains(key) {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if inflightKeys.contains(key) {
            inflightWaiters[key, default: []].append(completion)
            lock.unlock()
            return
        }
        inflightKeys.insert(key)
        inflightWaiters[key] = [completion]
        lock.unlock()

        genQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            // Block here (on the background pool), not on the caller's thread.
            self.genSemaphore.wait()

            let thumb = ThumbnailGenerator.generate(from: url, maxSize: maxSize)

            if let thumb = thumb {
                // Save to disk via temp file + atomic replace so readers never
                // see a partially written PNG.
                let diskURL = self.cacheDir.appendingPathComponent("\(key).png")
                let tmpURL = self.cacheDir.appendingPathComponent("\(key).\(UUID().uuidString).tmp")
                if let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, thumb, nil)
                    if CGImageDestinationFinalize(dest) {
                        _ = try? FileManager.default.replaceItemAt(diskURL, withItemAt: tmpURL)
                    }
                    try? FileManager.default.removeItem(at: tmpURL)
                }
                self.insertMemory(key: key, image: thumb)
            } else {
                self.lock.lock()
                self.failedKeys.insert(key)
                self.lock.unlock()
            }

            self.deliver(key: key, image: thumb)
            self.genSemaphore.signal()
        }
    }

    private func deliver(key: String, image: CGImage?) {
        lock.lock()
        inflightKeys.remove(key)
        let waiters = inflightWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        for completion in waiters {
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Drop memory + disk cache entries for a deleted file.
    func remove(for url: URL) {
        let key = cacheKey(for: url)
        lock.lock()
        memoryCache.removeValue(forKey: key)
        unlinkLRUNode(key)
        failedKeys.remove(key)
        lock.unlock()
        // Memo entries are keyed "path|mtime": purge every entry for this
        // path (a bare-path lookup would never hit).
        let prefix = url.path + "|"
        keyMemo = keyMemo.filter { !$0.key.hasPrefix(prefix) }
        keyMemoInsertionOrder.removeAll { $0.hasPrefix(prefix) }
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("\(key).png"))
    }

    private func insertMemory(key: String, image: CGImage) {
        lock.lock()
        memoryCache[key] = image
        touchLRU(key)
        trimMemoryCacheLocked()
        lock.unlock()
    }

    /// Mark `key` as most-recently-used. O(1): node lookup via map, splice
    /// via prev/next pointers. Must be called with `lock` held.
    private func touchLRU(_ key: String) {
        if let node = lruNodes[key] {
            // Already in list: move to tail if not there already.
            if node === lruTail { return }
            detachLRUNode(node)
            attachLRUNodeAsTail(node)
        } else {
            let node = LRUNode(key)
            lruNodes[key] = node
            attachLRUNodeAsTail(node)
            lruCount += 1
        }
    }

    private func detachLRUNode(_ node: LRUNode) {
        node.prev?.next = node.next
        if node === lruHead { lruHead = node.next }
        node.next?.prev = node.prev
        node.prev = nil
        node.next = nil
    }

    private func attachLRUNodeAsTail(_ node: LRUNode) {
        node.prev = lruTail
        lruTail?.next = node
        lruTail = node
        if lruHead == nil { lruHead = node }
    }

    private func unlinkLRUNode(_ key: String) {
        guard let node = lruNodes.removeValue(forKey: key) else { return }
        detachLRUNode(node)
        lruCount -= 1
    }

    private func trimMemoryCacheLocked() {
        while lruCount > maxMemoryCache, let oldest = lruHead {
            unlinkLRUNode(oldest.key)
            memoryCache.removeValue(forKey: oldest.key)
        }
    }
}
