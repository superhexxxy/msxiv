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

        switch sortBy {
        case "date":
            self.files = tempFiles.sorted {
                modDate(of: $0) < modDate(of: $1)
            }
        case "size":
            self.files = tempFiles.sorted {
                fileSize(of: $0) < fileSize(of: $1)
            }
        default:
            // Alphabetical by filename (locale-aware, matching nsxiv behavior)
            self.files = tempFiles.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }

    private func modDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    private func fileSize(of url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
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
