import Foundation
import CoreServices

class FileWatcher {
    private var stream: FSEventStreamRef?
    /// Opaque pointer handed to FSEventStreamContext (see `makeContext()`):
    /// retained for the stream's whole lifetime, released in `stopStream()`.
    private var contextInfo: UnsafeMutableRawPointer?
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
    ///
    /// Must be called from the main thread (the stream is scheduled on the
    /// main dispatch queue; mutating its bookkeeping off-main would race).
    func watch(file url: URL, onModify: @escaping () -> Void) {
        assert(Thread.isMainThread, "FileWatcher.watch must run on the main thread")
        self.onModify = onModify
        self.currentPath = url.path

        let dir = url.deletingLastPathComponent().path
        if let watchedDir = watchedDir, watchedDir == dir, stream != nil {
            return // Already streaming this directory; only the target changed.
        }

        stopStream()
        watchedDir = dir

        var context = makeContext()

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, numEvents, eventPaths, eventFlags, _) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let watched = watcher.currentPath else { return }

            // With kFSEventStreamCreateFlagUseCFTypes, `eventPaths` is a
            // CFArray of CFString paths. Bridge it to NSArray with a
            // conditional downcast: safe against any unexpected element type
            // (skipped via nil-coalescing instead of trapping), using only
            // API that exists on CFArray in the Swift overlay (it has neither
            // `count` nor subscripting).
            guard numEvents > 0 else { return }
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let count = min(Int(numEvents), paths.count)
            guard count > 0 else { return }

            for i in 0..<count {
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

    /// Build the FSEventStreamContext with a properly managed `info` pointer.
    ///
    /// The old code used `Unmanaged.passUnretained(self)` with `release: nil`,
    /// which is only safe while the watcher outlives the stream. Here we take
    /// an explicit +1 retain instead, so even if CoreServices kept the context
    /// alive past our last `stopStream()` call, the callback could never touch
    /// a dangling pointer. The matching release happens in `stopStream()`,
    /// after the stream has been invalidated (no callbacks can run after that).
    private func makeContext() -> FSEventStreamContext {
        let ptr = Unmanaged.passRetained(self).toOpaque()
        contextInfo = ptr
        return FSEventStreamContext(
            version: 0,
            info: ptr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
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
        self.stream = nil
        currentPath = nil
        // Balance the +1 retain from `makeContext()`. Safe here because the
        // stream was just invalidated: no further callbacks will dereference
        // the pointer.
        if let info = contextInfo {
            Unmanaged<FileWatcher>.fromOpaque(info).release()
            contextInfo = nil
        }
    }

    deinit {
        stop()
    }
}
