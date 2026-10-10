import AppKit

enum ViewMode {
    case image
    case thumbnail
}

class AppWindow: NSWindow {
    var imageView: ImageView!
    var thumbnailView: ThumbnailView!
    var scrollView: NSScrollView!
    var currentMode: ViewMode = .image
    
    init(config: AppConfig) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        
        self.title = "msxiv"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        self.center()
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 200, height: 200)
        
        // --- Image View ---
        self.imageView = ImageView(frame: self.contentView!.bounds)
        self.imageView.autoresizingMask = [.width, .height]
        self.imageView.backgroundColor = config.nsBackgroundColor
        
        // --- Thumbnail View (inside scroll view) ---
        self.scrollView = NSScrollView(frame: self.contentView!.bounds)
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.hasVerticalScroller = true
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.autohidesScrollers = true
        self.scrollView.borderType = .noBorder
        self.scrollView.drawsBackground = false
        
        self.thumbnailView = ThumbnailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.thumbnailView.thumbnailSize = config.thumbnailSize
        self.thumbnailView.autoresizingMask = [.width]
        self.scrollView.documentView = self.thumbnailView

        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(fullscreenChanged(_:)), name: name, object: self)
        }

        // Start in image mode
        self.contentView?.addSubview(self.imageView)

        // Honor `status_bar = false` from the config (ImageView skips both
        // drawing and layout reservation when this is off).
        self.imageView.showsStatusBar = config.statusBar
        self.thumbnailView.showsStatusBar = config.statusBar
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// True while entering/exiting fullscreen (styleMask lags the animation).
    var fullscreenBusy = false

    @objc private func fullscreenChanged(_ n: Notification) {
        switch n.name {
        case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
            fullscreenBusy = true
        default:
            fullscreenBusy = false
        }
    }

    var isFullscreenLike: Bool {
        styleMask.contains(.fullScreen) || fullscreenBusy
    }

    /// Focus the active mode's view. Logs on failure so a lost responder
    /// chain is diagnosable instead of silently swallowing all keys.
    func focusCurrentView() {
        let v: NSView = currentMode == .thumbnail ? thumbnailView : imageView
        if !makeFirstResponder(v) {
            NSLog("msxiv: makeFirstResponder failed for %@ (mode %@)", "\(type(of: v))", "\(currentMode)")
        }
    }
    
    func switchToImageMode() {
        currentMode = .image
        scrollView.removeFromSuperview()
        // Views removed from the hierarchy miss resizes: re-sync the frame,
        // otherwise consecutive t-toggles show a stale-sized canvas.
        if let bounds = contentView?.bounds {
            imageView.frame = bounds
        }
        if imageView.superview == nil {
            contentView?.addSubview(imageView)
        }
        focusCurrentView()
    }
    
    func switchToThumbnailMode() {
        currentMode = .thumbnail
        imageView.removeFromSuperview()
        if let bounds = contentView?.bounds {
            scrollView.frame = bounds
            var f = thumbnailView.frame
            f.size.width = max(scrollView.contentSize.width, 100)
            thumbnailView.frame = f
        }
        if scrollView.superview == nil {
            contentView?.addSubview(scrollView)
        }
        thumbnailView.updateFrameHeight()
        thumbnailView.preloadVisible()
        focusCurrentView()
    }

    // MARK: - Status-bar window dragging (no titlebar to grab)

    private var dragAnchor: NSPoint?
    private var frameAnchor: NSPoint?

    func beginMoveDrag() {
        guard !isFullscreenLike else { return }
        dragAnchor = NSEvent.mouseLocation
        frameAnchor = frame.origin
    }

    func continueMoveDrag() {
        guard let a = dragAnchor, let f = frameAnchor else { return }
        let cur = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: f.x + cur.x - a.x, y: f.y + cur.y - a.y))
    }

    func endMoveDrag() {
        dragAnchor = nil
        frameAnchor = nil
    }

    /// Resize the window so the image fits 1:1 (clamped to 92% of the
    /// visible screen). Keeps the window center stable. No-op in fullscreen.
    ///
    /// NOTE: the renderer draws the image rect using pixel dims as points
    /// (a 570px screenshot fills a 570pt window at zoom 1.0), so the window
    /// must be sized in the same units. Do NOT divide by backingScaleFactor
    /// here — that would size every window at half scale on Retina and show
    /// a cropped image. Oversized photos are already handled by the 0.92
    /// screen clamp below; a 6000px photo can never request a 6000pt window.
    func fitWindowToImage(_ img: CGImage) {
        var w = CGFloat(img.width)
        var h = CGFloat(img.height)
        // The renderer reserves ImageView.statusBarHeight of content height
        // for the status bar; include it so a 100%-zoom image fits exactly.
        if imageView.showsStatusBar {
            h += ImageView.statusBarHeight
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let shrink = min(1, (screen.width * 0.92) / w, (screen.height * 0.92) / h)
        w *= shrink
        h *= shrink
        resizeToContentSize(NSSize(width: w, height: h))
    }

    /// Comfortable grid size for thumbnail mode. No-op in fullscreen.
    func resizeForThumbnails() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1020, screen.width * 0.85)
        let h = min(760, screen.height * 0.8)
        resizeToContentSize(NSSize(width: w, height: h))
    }

    /// Center-preserving, screen-clamped resize. No-op in/around fullscreen.
    func resizeToContentSize(_ size: NSSize) {
        guard !isFullscreenLike else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(size.width, minSize.width), screen.width)
        let h = min(max(size.height, minSize.height), screen.height)
        let contentRect = NSRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
        var frameRect = frameRect(forContentRect: contentRect)
        frameRect.origin.x = max(screen.minX, min(frameRect.origin.x, screen.maxX - frameRect.width))
        frameRect.origin.y = max(screen.minY, min(frameRect.origin.y, screen.maxY - frameRect.height))
        setFrame(frameRect, display: true)
    }
}
