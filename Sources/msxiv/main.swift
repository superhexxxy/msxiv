import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: AppWindow!
    var imageStore: ImageStore!
    var config: AppConfig!
    var fileWatcher: FileWatcher!
    var startInThumbnailMode = false
    var pendingDeleteIndex: Int?
    var slideshowTimer: Timer?
    var slideshowDelay: Double = 3.0
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = AppConfig()
        fileWatcher = FileWatcher()
        slideshowDelay = config.slideshowDelay
        var args = Array(CommandLine.arguments.dropFirst())
        
        if args.contains("-h") || args.contains("--help") {
            printUsage()
            NSApp.terminate(nil)
            return
        }
        if args.contains("-t") || args.contains("--thumbnail") {
            startInThumbnailMode = true
            args.removeAll { $0 == "-t" || $0 == "--thumbnail" }
        }
        
        if args.isEmpty {
            printUsage()
            NSApp.terminate(nil)
            return
        }
        
        imageStore = ImageStore(paths: args, sortBy: config.sortBy, recursive: config.recursive)
        
        if imageStore.files.isEmpty {
            print("msxiv: no valid images found")
            NSApp.terminate(nil)
            return
        }
        
        window = AppWindow(config: config)
        setupCallbacks()
        installQuitGuard()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.focusCurrentView()
        
        if startInThumbnailMode {
            enterThumbnailMode()
        } else {
            loadImage()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-assert first responder when returning via Cmd-Tab / click,
        // otherwise keys fall through to the window and beep.
        if window == nil { return }
        window.focusCurrentView()
    }

    /// App-level safety net: q and Escape work even if the responder chain
    /// ever breaks (a stuck quit is unacceptable). No text fields exist, so
    /// there is nothing to steal typing from. Command-modified keys are left
    /// alone, and an active delete prompt keeps y/n/Esc semantics in the views.
    func installQuitGuard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                let promptUp = self.window.imageView.confirmPrompt != nil
                    || self.window.thumbnailView.confirmPrompt != nil
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if chars == "q" && !promptUp {
                    NSApp.terminate(nil)
                    return nil
                }
                if event.keyCode == 53 && promptUp {
                    self.clearDeletePrompt()
                    return nil
                }
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        fileWatcher?.stop()
        if let store = imageStore, !store.markedFiles.isEmpty {
            for file in store.markedFiles.sorted(by: { $0.path < $1.path }) {
                print(file.path)
            }
        }
        return .terminateNow
    }
    
    private func setupCallbacks() {
        window.imageView.onAction = { [weak self] action in self?.handleImageAction(action) }
        window.imageView.onZoomChanged = { [weak self] in self?.updateImageInfo() }
        
        window.thumbnailView.onSelect = { [weak self] index in
            self?.imageStore.currentIndex = index
            self?.window.switchToImageMode()
            self?.loadImage()
        }
        window.thumbnailView.onToggleMode = { [weak self] in
            self?.window.switchToImageMode()
            self?.loadImage()
        }
        window.thumbnailView.onMark = { [weak self] index in
            guard let self = self else { return }
            self.imageStore.currentIndex = index
            self.imageStore.toggleMark()
            self.window.thumbnailView.markedFiles = self.imageStore.markedFiles
            self.window.thumbnailView.needsDisplay = true
        }
        window.thumbnailView.onQuit = { NSApp.terminate(nil) }
        
        // Handle first/last/fullscreen/delete/clipboard actions in thumbnail mode
        window.thumbnailView.onAction = { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .first: self.window.thumbnailView.selectAndScroll(to: 0)
            case .last: self.window.thumbnailView.selectAndScroll(to: self.imageStore.files.count - 1)
            case .toggleFullscreen: self.window.toggleFullScreen(nil)
            case .deleteRequest: self.requestDeleteInThumbnail()
            case .confirmYes: self.performDelete()
            case .confirmNo: self.clearDeletePrompt()
            case .copyPath: self.copySelectedThumbnailPath()
            case .openExternal: self.openSelectedThumbnail()
            default: break
            }
        }
    }
    
    // MARK: - Image Mode
    
    func loadImage() {
        guard let url = imageStore.currentFile else { return }
        if let cgImage = ImageLoader.load(from: url) {
            window.imageView.image = cgImage
            window.imageView.zoom = 1.0
            window.imageView.offset = .zero
            window.imageView.rotation = 0.0
            window.imageView.isMarked = imageStore.isCurrentMarked
            window.imageView.statusInfo = nil // Reset script output

            window.fitWindowToImage(cgImage)
            updateImageInfo()
            runImageScripts(for: url)

            // Start watching this file for modifications
            fileWatcher.watch(file: url) { [weak self] in
                self?.loadImage()
            }
        } else {
            window.imageView.image = nil
            window.title = "msxiv - (failed to load \(url.lastPathComponent))"
        }
    }
    
    func updateImageInfo() {
        guard let url = imageStore.currentFile, let img = window.imageView.image else { return }
        let slideshow: String? = slideshowTimer != nil
            ? "▶slideshow \(String(format: "%.1f", slideshowDelay))s" : nil
        window.imageView.defaultInfo = ImageInfo.format(
            index: imageStore.currentIndex,
            total: imageStore.files.count,
            filename: url.lastPathComponent,
            width: img.width,
            height: img.height,
            zoom: window.imageView.zoom,
            fileSize: ImageInfo.fileSize(for: url),
            dateTaken: ImageInfo.photoDate(for: url),
            slideshow: slideshow
        )
        window.imageView.needsDisplay = true
    }

    /// Flash a transient message in the status bar (auto-clears after 1.5s
    /// unless the user navigated away meanwhile).
    func flashStatus(_ text: String) {
        guard let url = imageStore.currentFile else { return }
        let path = url.path
        window.imageView.statusInfo = text
        window.imageView.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self,
                  self.imageStore.currentFile?.path == path,
                  self.window.imageView.statusInfo == text else { return }
            self.window.imageView.statusInfo = nil
            self.window.imageView.needsDisplay = true
        }
    }
    
    func runImageScripts(for url: URL) {
        // Window Title
        ScriptRunner.runScript(name: "win-title", arguments: [url.path]) { [weak self] output in
            guard let self = self else { return }
            self.window.title = output ?? "msxiv - \(url.lastPathComponent)"
        }
        
        // Image Info
        ScriptRunner.runScript(name: "image-info", arguments: [url.path]) { [weak self] output in
            guard let self = self else { return }
            self.window.imageView.statusInfo = output
            self.window.imageView.needsDisplay = true
        }
    }
    
    func handleImageAction(_ action: AppAction) {
        switch action {
        case .next:
            if imageStore.currentIndex < imageStore.files.count - 1 {
                imageStore.currentIndex += 1
                loadImage()
            }
        case .prev:
            if imageStore.currentIndex > 0 {
                imageStore.currentIndex -= 1
                loadImage()
            }
        case .first:
            imageStore.currentIndex = 0
            loadImage()
        case .last:
            imageStore.currentIndex = imageStore.files.count - 1
            loadImage()
        case .quit:
            NSApp.terminate(nil)
        case .rotate:
            window.imageView.rotation += 90
        case .fit:
            guard let img = window.imageView.image, let cv = window.contentView else { return }
            let scaleX = cv.bounds.width / CGFloat(img.width)
            let availH = cv.bounds.height - ImageView.statusBarHeight
            let scaleY = availH / CGFloat(img.height)
            window.imageView.zoom = min(scaleX, scaleY)
            window.imageView.offset = .zero
            updateImageInfo()
        case .zoomIn:
            window.imageView.zoom *= config.zoomIncrement
            updateImageInfo()
        case .zoomOut:
            window.imageView.zoom /= config.zoomIncrement
            updateImageInfo()
        case .panLeft:  window.imageView.offset.x += 50 / window.imageView.zoom
        case .panRight: window.imageView.offset.x -= 50 / window.imageView.zoom
        case .panUp:    window.imageView.offset.y += 50 / window.imageView.zoom
        case .panDown:  window.imageView.offset.y -= 50 / window.imageView.zoom
        case .toggleThumbnail:
            enterThumbnailMode()
        case .mark:
            imageStore.toggleMark()
            window.imageView.isMarked = imageStore.isCurrentMarked
            let markIndicator = imageStore.isCurrentMarked ? " [marked]" : ""
            window.title = "msxiv - \(imageStore.currentFile?.lastPathComponent ?? "")\(markIndicator)"
        case .runKeyHandler:
            if let file = imageStore.currentFile {
                ScriptRunner.runKeyHandler(action: "default", files: [file])
            }
        case .toggleSlideshow:
            toggleSlideshow()
        case .slideshowFaster:
            adjustSlideshowDelay(by: -0.5)
        case .slideshowSlower:
            adjustSlideshowDelay(by: 0.5)
        case .copyPath:
            if let file = imageStore.currentFile { copyPath(file) }
        case .openExternal:
            if let file = imageStore.currentFile { openExternal(file) }
        case .zoomActual:
            window.imageView.zoom = 1.0
            window.imageView.offset = .zero
            updateImageInfo()
        case .saveRotation:
            saveRotation()
        case .deleteRequest:
            guard let url = imageStore.currentFile else { break }
            pendingDeleteIndex = imageStore.currentIndex
            window.imageView.confirmPrompt = "Delete '\(url.lastPathComponent)'?  [y]es / [n]o"
        case .confirmYes:
            performDelete()
        case .confirmNo:
            clearDeletePrompt()
        case .toggleFullscreen:
            window.toggleFullScreen(nil)
        case .fitWindow:
            if let img = window.imageView.image {
                window.imageView.zoom = 1.0
                window.imageView.offset = .zero
                window.fitWindowToImage(img)
                updateImageInfo()
            }
        }
    }

    // MARK: - Delete (moves to Trash, Y/N confirmed)

    func requestDeleteInThumbnail() {
        let index = window.thumbnailView.selectedIndex
        guard index >= 0, index < imageStore.files.count else { return }
        pendingDeleteIndex = index
        let url = imageStore.files[index]
        window.thumbnailView.confirmPrompt = "Delete '\(url.lastPathComponent)'?  [y]es / [n]o"
    }

    func clearDeletePrompt() {
        pendingDeleteIndex = nil
        window.imageView.confirmPrompt = nil
        window.thumbnailView.confirmPrompt = nil
    }

    func performDelete() {
        guard let index = pendingDeleteIndex,
              index >= 0, index < imageStore.files.count else {
            clearDeletePrompt()
            return
        }
        let url = imageStore.files[index]

        // Drop thumbnail cache BEFORE trashing (cache key needs the live file).
        ThumbnailCache.shared.remove(for: url)
        window.thumbnailView.thumbInfoCache.removeValue(forKey: url.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            if let data = "msxiv: delete failed: \(error)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            clearDeletePrompt()
            return
        }

        imageStore.files.remove(at: index)
        imageStore.markedFiles.remove(url)
        clearDeletePrompt()

        if imageStore.files.isEmpty {
            fileWatcher.stop()
            NSApp.terminate(nil)
            return
        }
        imageStore.currentIndex = min(imageStore.currentIndex, imageStore.files.count - 1)

        if window.currentMode == .thumbnail {
            window.thumbnailView.files = imageStore.files
            window.thumbnailView.markedFiles = imageStore.markedFiles
            window.thumbnailView.selectedIndex = min(window.thumbnailView.selectedIndex, imageStore.files.count - 1)
            let total = imageStore.files.count
            let marked = imageStore.markedFiles.count
            window.thumbnailView.defaultInfo = "[\(window.thumbnailView.selectedIndex + 1)/\(total)] \(marked) marked"
            window.thumbnailView.didDeleteFiles()
            window.title = "msxiv - thumbnails (\(total) images)"
        } else {
            window.thumbnailView.selectedIndex = imageStore.currentIndex
            loadImage()
        }
    }
    
    // MARK: - Slideshow / clipboard / rotation-save

    func toggleSlideshow() {
        if slideshowTimer != nil {
            stopSlideshow()
            flashStatus("Slideshow stopped")
        } else {
            restartSlideshowTimer()
            flashStatus("Slideshow ▶ every \(String(format: "%.1f", slideshowDelay))s  ([ ] adjust, s stops)")
        }
        updateImageInfo()
    }

    func restartSlideshowTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowDelay, repeats: true) { [weak self] _ in
            self?.advanceSlideshow()
        }
    }

    func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        updateImageInfo()
    }

    func advanceSlideshow() {
        guard !imageStore.files.isEmpty else { stopSlideshow(); return }
        imageStore.currentIndex = (imageStore.currentIndex + 1) % imageStore.files.count
        loadImage()
    }

    func adjustSlideshowDelay(by delta: Double) {
        slideshowDelay = min(30, max(0.5, slideshowDelay + delta))
        if slideshowTimer != nil { restartSlideshowTimer() }
        flashStatus("Slideshow delay \(String(format: "%.1f", slideshowDelay))s")
        updateImageInfo()
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        flashStatus("Copied: \(url.path)")
    }

    func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copySelectedThumbnailPath() {
        let i = window.thumbnailView.selectedIndex
        guard i >= 0, i < imageStore.files.count else { return }
        let url = imageStore.files[i]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func openSelectedThumbnail() {
        let i = window.thumbnailView.selectedIndex
        guard i >= 0, i < imageStore.files.count else { return }
        NSWorkspace.shared.open(imageStore.files[i])
    }

    /// Bake the on-screen rotation into the file (destructive, JPEG q0.95).
    func saveRotation() {
        guard let url = imageStore.currentFile else { return }
        let turns = Int(((window.imageView.rotation.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 90)
        guard turns != 0 else {
            flashStatus("Nothing to save (press r first)")
            return
        }
        if ImageSaver.rotateCW(url, quarterTurns: turns) {
            window.imageView.rotation = 0
            loadImage()
            flashStatus("Saved \(turns * 90)° rotation to disk")
        } else {
            flashStatus("Save failed")
        }
    }

    // MARK: - Thumbnail Mode

    func enterThumbnailMode() {
        stopSlideshow()
        fileWatcher.stop()
        window.thumbnailView.files = imageStore.files
        window.thumbnailView.markedFiles = imageStore.markedFiles
        window.thumbnailView.selectedIndex = imageStore.currentIndex
        window.thumbnailView.statusInfo = nil
        
        let total = imageStore.files.count
        let marked = imageStore.markedFiles.count
        window.thumbnailView.defaultInfo = "[\(imageStore.currentIndex + 1)/\(total)] \(marked) marked"
        
        window.switchToThumbnailMode()
        window.resizeForThumbnails()
        window.thumbnailView.selectAndScroll(to: imageStore.currentIndex)
        window.thumbnailView.preloadVisible()
        window.title = "msxiv - thumbnails (\(total) images)"
    }
    
    private func printUsage() {
        print("Usage: msxiv [OPTIONS] [FILE|DIRECTORY...]")
        print("Options:")
        print("  -t, --thumbnail   Start in thumbnail mode")
        print("  -h, --help        Show this help message")
        print()
        print("Image mode keys:")
        print("  h/j/k/l or arrows  Pan")
        print("  Left/Right/Space   Prev/Next image")
        print("  w                  Fit to window")
        print("  W (Shift+w)        Fit window to image")
        print("  f                  Toggle fullscreen")
        print("  r                  Rotate 90° (view)")
        print("  R (Shift+r)        Rotate 90° and save to disk")
        print("  1                  Zoom to 100% (true pixels)")
        print("  +/-                Zoom in/out  ([ ] slideshow delay)")
        print("  s                  Slideshow on/off")
        print("  c                  Copy file path")
        print("  o                  Open in default app")
        print("  x                  Mark/unmark file")
        print("  t                  Toggle thumbnail mode")
        print("  g/G                First/Last image")
        print("  ;                  Run key-handler script")
        print("  d                  Delete file (confirm y/n)")
        print("  q                  Quit")
        print()
        print("Thumbnail mode keys:")
        print("  h/j/k/l or arrows  Navigate grid")
        print("  Return             Open selected image")
        print("  x                  Mark/unmark file")
        print("  c                  Copy file path")
        print("  o                  Open in default app")
        print("  d                  Delete file (confirm y/n)")
        print("  t                  Back to image mode")
        print("  g/G                Jump to first/last")
        print("  f                  Toggle fullscreen")
        print("  q                  Quit")
        print()
        print("Scripts (in ~/.config/msxiv/):")
        print("  key-handler   Executed when ; is pressed (receives file paths on stdin)")
        print("  image-info    Executed when image loads (output shown in status bar)")
        print("  thumb-info    Executed for each thumbnail (output shown below thumbnail)")
        print("  win-title     Executed when image loads (output sets window title)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
