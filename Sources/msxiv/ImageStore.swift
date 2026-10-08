import Foundation

class ImageStore {
    var files: [URL] = []
    var currentIndex: Int = 0
    var markedFiles: Set<URL> = []
    let sortBy: String
    let recursive: Bool

    init(paths: [String], sortBy: String = "name", recursive: Bool = false) {
        self.sortBy = sortBy
        self.recursive = recursive
        var tempFiles: [URL] = []
        let validExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "tiff"]
        let fm = FileManager.default

        for path in paths {
            let url = URL(fileURLWithPath: path).standardized
            var isDir: ObjCBool = false

            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if recursive {
                        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                            for case let file as URL in e
                                where validExtensions.contains(file.pathExtension.lowercased()) {
                                tempFiles.append(file)
                            }
                        }
                    } else if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        tempFiles.append(contentsOf: contents.filter { validExtensions.contains($0.pathExtension.lowercased()) })
                    }
                } else {
                    if validExtensions.contains(url.pathExtension.lowercased()) {
                        tempFiles.append(url)
                    }
                }
            }
        }

        // Schwartzian transform: precompute each file's sort key with one
        // cheap `stat` per file (O(n) syscalls), then sort the cached pairs.
        // The old comparator re-queried FileManager attributes on every
        // compare — O(2·n log n) syscalls + NSDictionary allocations.
        switch sortBy {
        case "date":
            self.files = tempFiles
                .map { (url: $0, key: ImageStore.statInfo(of: $0).date) }
                .sorted { $0.key < $1.key }
                .map { $0.url }
        case "size":
            self.files = tempFiles
                .map { (url: $0, key: ImageStore.statInfo(of: $0).size) }
                .sorted { $0.key < $1.key }
                .map { $0.url }
        default:
            // Alphabetical by filename (locale-aware, matching nsxiv behavior)
            self.files = tempFiles.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }

    /// One raw `stat()` per file. Keys are precomputed once (O(n) syscalls),
    /// then the sort compares cached values — no filesystem traffic inside
    /// the comparator, which previously ran O(2·n log n) heavy
    /// FileManager.attributesOfItem calls (each allocating an NSDictionary).
    private struct StatInfo { let date: Date; let size: UInt64 }

    private static func statInfo(of url: URL) -> StatInfo {
        var s = stat()
        guard stat(url.path, &s) == 0 else {
            return StatInfo(date: .distantPast, size: 0)
        }
        #if os(macOS)
        let mtime = Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec)
                         + TimeInterval(s.st_mtimespec.tv_nsec) * 1e-9)
        #else
        let mtime = Date(timeIntervalSince1970: TimeInterval(s.st_mtim.tv_sec)
                         + TimeInterval(s.st_mtim.tv_nsec) * 1e-9)
        #endif
        return StatInfo(date: mtime, size: UInt64(max(0, s.st_size)))
    }
    
    var currentFile: URL? {
        guard !files.isEmpty, currentIndex >= 0, currentIndex < files.count else { return nil }
        return files[currentIndex]
    }
    
    func toggleMark() {
        guard let file = currentFile else { return }
        if markedFiles.contains(file) {
            markedFiles.remove(file)
        } else {
            markedFiles.insert(file)
        }
    }
    
    var isCurrentMarked: Bool {
        guard let file = currentFile else { return false }
        return markedFiles.contains(file)
    }
}
