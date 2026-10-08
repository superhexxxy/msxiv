import Foundation
import CoreServices

class FileWatcher {
    private var stream: FSEventStreamRef?
    private var currentPath: String?
    private var onModify: (() -> Void)?

    /// Start watching a file for modifications. Calls `onModify` when the file changes.
    func watch(file url: URL, onModify: @escaping () -> Void) {
        stop()

        self.currentPath = url.path
        self.onModify = onModify

        let pathsToWatch = [url.deletingLastPathComponent().path] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, numEvents, eventPaths, eventFlags, _) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let watched = watcher.currentPath else { return }

            // With UseCFTypes, eventPaths is a CFArray of CFString paths.
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]

            for i in 0..<numEvents {
                guard i < paths.count else { continue }
                let path = paths[i]
                let flags = eventFlags[i]

                let modified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
                let renamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                let created = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                let removed = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
                let inodeMeta = (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0

                if (modified || renamed || created || removed || inodeMeta) &&
                    (path == watched || FileManager.default.fileExists(atPath: watched)) {
                    DispatchQueue.main.async {
                        watcher.onModify?()
                    }
                    break
                }
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // Latency in seconds (debounce rapid changes)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        currentPath = nil
    }

    deinit {
        stop()
    }
}
