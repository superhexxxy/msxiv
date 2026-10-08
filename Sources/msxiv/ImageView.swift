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

    var image: CGImage? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1.0 { didSet { needsDisplay = true; onZoomChanged?() } }
    var offset: CGPoint = .zero { didSet { needsDisplay = true } }
    var rotation: CGFloat = 0.0 { didSet { needsDisplay = true } }
    var backgroundColor: NSColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
    var isMarked: Bool = false { didSet { needsDisplay = true } }
    
    var statusInfo: String? // Output from image-info script
    var defaultInfo: String = "" // Fallback info string
    var confirmPrompt: String? // When set: red Y/N bar replaces the status bar
    
    var onAction: ((AppAction) -> Void)?
    var onZoomChanged: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        backgroundColor.setFill()
        ctx.fill(bounds)
        
        guard let image = image else { return }
        
        ctx.saveGState()
        // Center in the area ABOVE the status bar so the bar never covers pixels.
        let barH = ImageView.statusBarHeight
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
        
        // --- Draw Status Bar (or red confirm bar) ---
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let textSize = (infoText as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: 8, y: (barHeight - textSize.height) / 2, width: bounds.width - 16, height: textSize.height)
        (infoText as NSString).draw(in: textRect, withAttributes: attrs)
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
        needsDisplay = true
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
