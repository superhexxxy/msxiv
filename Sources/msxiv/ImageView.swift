import AppKit

enum AppAction {
    case next, prev, quit, rotate, fit, zoomIn, zoomOut
    case panLeft, panRight, panUp, panDown
    case toggleThumbnail, mark
    case first, last
    case runKeyHandler  // Added for ; key
    case toggleFullscreen, fitWindow
    case deleteRequest, confirmYes, confirmNo
    case toggleSlideshow, slideshowFaster, slideshowSlower
    case copyPath, openExternal, zoomActual, saveRotation
}

class ImageView: NSView {
    static let statusBarHeight: CGFloat = 22

    /// Honor the `status_bar` config option (AppConfig.statusBar): when false,
    /// no status bar is drawn and layout reserves nothing for it. Set once by
    /// AppWindow at view creation; reads happen only on the main thread during
    /// drawing/layout, so a plain var is safe here.
    var showsStatusBar = true

    // Redraws are coalesced via needsDisplay = true: a change that lands while
    // the view is already dirty skips redundant display-cycle scheduling.
    var image: CGImage? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1.0 { didSet { needsDisplay = true; onZoomChanged?() } }
    var offset: CGPoint = .zero { didSet { needsDisplay = true } }
    var rotation: CGFloat = 0.0 { didSet { needsDisplay = true } }
    var backgroundColor: NSColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
    var isMarked: Bool = false { didSet { needsDisplay = true } }
    
    var statusInfo: String? { didSet { needsDisplay = true } } // Output from image-info script
    var defaultInfo: String = "" { didSet { needsDisplay = true } } // Fallback info string
    var confirmPrompt: String? { didSet { needsDisplay = true } } // When set: red Y/N bar replaces the status bar

    /// Cached NSString + attributes for the status bar text. The draw path
    /// used to re-bridge and rebuild these every frame.
    private var cachedStatusText: NSString?
    private var cachedStatusAttrs: [NSAttributedString.Key: Any]?
    private var cachedStatusLineHeight: CGFloat?

    private func statusAttrs() -> [NSAttributedString.Key: Any] {
        if let attrs = cachedStatusAttrs { return attrs }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        cachedStatusAttrs = attrs
        return attrs
    }

    private func statusString(_ text: String) -> NSString {
        if let cached = cachedStatusText, cached as String == text { return cached }
        let ns = text as NSString
        cachedStatusText = ns
        return ns
    }
    
    var onAction: ((AppAction) -> Void)?
    var onZoomChanged: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        backgroundColor.setFill()
        ctx.fill(bounds)
        
        guard let image = image else { return }
        
        ctx.saveGState()
        // Center in the area ABOVE the status bar so the bar never covers
        // pixels (full height when the bar is hidden via status_bar=false).
        let barH = showsStatusBar ? ImageView.statusBarHeight : 0
        ctx.translateBy(x: bounds.midX, y: barH + (bounds.height - barH) / 2)
        ctx.rotate(by: rotation * .pi / 180.0)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: offset.x, y: offset.y)
        
        let imgRect = CGRect(x: -Double(image.width) / 2.0, y: -Double(image.height) / 2.0,
                             width: Double(image.width), height: Double(image.height))
        ctx.draw(image, in: imgRect)
        ctx.restoreGState()
        
        if isMarked {
            NSColor.systemGreen.setFill()
            ctx.fill(NSRect(x: 8, y: bounds.height - 18, width: 10, height: 10))
        }
        
        // --- Draw Status Bar (or red confirm bar) — skipped entirely when
        // the user disabled it via `status_bar = false`. (GState is already
        // balanced by the restoreGState above; no extra restore here.) ---
        guard showsStatusBar else { return }
        let barHeight: CGFloat = ImageView.statusBarHeight
        let barRect = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let infoText: String
        if let prompt = confirmPrompt {
            NSColor(calibratedRed: 0.45, green: 0.1, blue: 0.1, alpha: 0.92).setFill()
            ctx.fill(barRect)
            infoText = prompt
        } else {
            NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
            ctx.fill(barRect)
            infoText = statusInfo ?? defaultInfo
        }
        let ns = statusString(infoText)
        let attrs = statusAttrs()
        // Monospaced 11pt: uniform line height -> measure once, reuse.
        if cachedStatusLineHeight == nil {
            cachedStatusLineHeight = ("X" as NSString).size(withAttributes: attrs).height
        }
        let textRect = NSRect(x: 8, y: (barHeight - cachedStatusLineHeight!) / 2, width: bounds.width - 16, height: cachedStatusLineHeight!)
        ns.draw(in: textRect, withAttributes: attrs)
    }
    
    // MARK: - Mouse Events
    private var lastMouseLocation: CGPoint?
    private var movingWindow = false
    
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Bottom status-bar strip: drag it to move the (titlebar-less) window.
        let p = convert(event.locationInWindow, from: nil)
        if p.y < ImageView.statusBarHeight {
            movingWindow = true
            lastMouseLocation = nil
            (window as? AppWindow)?.beginMoveDrag()
            return
        }
        movingWindow = false
        lastMouseLocation = event.locationInWindow
    }
    
    override func mouseDragged(with event: NSEvent) {
        if movingWindow {
            (window as? AppWindow)?.continueMoveDrag()
            return
        }
        guard let last = lastMouseLocation else { return }
        let current = event.locationInWindow
        offset.x += (current.x - last.x) / zoom
        offset.y += (current.y - last.y) / zoom
        lastMouseLocation = current
        // offset.didSet already marked the view dirty — no extra needsDisplay.
    }
    
    override func mouseUp(with event: NSEvent) {
        movingWindow = false
        (window as? AppWindow)?.endMoveDrag()
        lastMouseLocation = nil
    }
    
    override func scrollWheel(with event: NSEvent) {
        let factor = event.deltaY > 0 ? 1.1 : 0.9
        zoom = max(0.05, min(zoom * factor, 50.0))
    }
    
    // MARK: - Keyboard
    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let actualChars = event.characters ?? ""

        // Modal Y/N confirm swallows everything except y / n / Esc.
        if confirmPrompt != nil {
            if keyCode == 53 { onAction?(.confirmNo); return }
            if let key = chars.first {
                if key == "y" { onAction?(.confirmYes); return }
                if key == "n" { onAction?(.confirmNo); return }
            }
            return
        }
        
        switch keyCode {
        case 123: onAction?(.prev)
        case 124: onAction?(.next)
        case 126: onAction?(.panUp)
        case 125: onAction?(.panDown)
        case 49:  onAction?(.next)
        default:
            if let key = chars.first {
                switch key {
                case "q": onAction?(.quit)
                case "r":
                    if actualChars.first == "R" { onAction?(.saveRotation) }
                    else { onAction?(.rotate) }
                case "1": onAction?(.zoomActual)
                case "s": onAction?(.toggleSlideshow)
                case "c": onAction?(.copyPath)
                case "o": onAction?(.openExternal)
                case "[": onAction?(.slideshowSlower)
                case "]": onAction?(.slideshowFaster)
                case "w":
                    if actualChars.first == "W" { onAction?(.fitWindow) }
                    else { onAction?(.fit) }
                case "f": onAction?(.toggleFullscreen)
                case "+", "=": onAction?(.zoomIn)
                case "-": onAction?(.zoomOut)
                case "h": onAction?(.panLeft)
                case "j": onAction?(.panDown)
                case "k": onAction?(.panUp)
                case "l": onAction?(.panRight)
                case "t": onAction?(.toggleThumbnail)
                case "x": onAction?(.mark)
                case "d": onAction?(.deleteRequest)
                case ";": onAction?(.runKeyHandler)
                case "g":
                    if actualChars.first == "G" { onAction?(.last) }
                    else { onAction?(.first) }
                default: super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
