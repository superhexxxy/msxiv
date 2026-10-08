import Foundation
import CoreServices

class FileWatcher {
    private var stream: FSEventStreamRef?
    /// Directory currently covered by the live stream.
    private var watchedDir: String?
    /// The file whose modifications should trigger a reload (nil = ignore all).
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

    /// Watch a file for modifications, calling `onModify` when it changes.
    ///
    /// The FSEventStream covers the file's *directory* and is kept alive while
    /// navigating within the same folder: `loadImage()` no longer tears down
    /// and re-creates a kernel stream on every keypress — switching images
    /// just swaps the target path.
    func watch(file url: URL, onModify: @escaping () -> Void) {
        self.onModify = onModify
        self.currentPath = url.path

        let dir = url.deletingLastPathComponent().path
        if let watchedDir = watchedDir, watchedDir == dir, stream != nil {
            return // Already streaming this directory; only the target changed.
        }

        stopStream()
        watchedDir = dir

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

        let pathsToWatch = [dir] as CFArray
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
        stopStream()
        watchedDir = nil
        currentPath = nil
        // Drop the caller's closure too: nothing should fire after stop(),
        // and it releases any captured references.
        onModify = nil
    }

    private func stopStream() {
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
