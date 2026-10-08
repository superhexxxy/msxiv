import Foundation
import CoreServices

class FileWatcher {
    private var stream: FSEventStreamRef?
    private var currentPath: String?
    private var onModify: (() -> Void)?

    /// Pure decision function (unit-tested): reload ONLY when the watched file
    /// itself changed. Never on sibling/directory noise (.DS_Store etc.).
    static func shouldReload(eventPath: String, flags: FSEventStreamEventFlags, watchedPath: String) -> Bool {
        let a = URL(fileURLWithPath: eventPath).standardized.resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: watchedPath).standardized.resolvingSymlinksInPath().path
        guard a == b else { return false }
        return (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
            || (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
            || (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
            || (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            || (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0
    }

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
                if FileWatcher.shouldReload(eventPath: paths[i], flags: eventFlags[i], watchedPath: watched) {
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
