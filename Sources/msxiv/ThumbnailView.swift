import AppKit

class ThumbnailView: NSView {
    var files: [URL] = []
    var markedFiles: Set<URL> = []
    var selectedIndex: Int = 0
    var thumbnailSize: Int = 128
    var padding: CGFloat = 8
    
    private var thumbnails: [Int: CGImage] = [:]
    private var pendingRequests: Set<Int> = []
    private var movingWindow = false
    var thumbInfoCache: [String: String] = [:] // Cache for thumb-info script output
    
    var statusInfo: String?
    var defaultInfo: String = ""
    var confirmPrompt: String? // When set: red Y/N bar replaces the status bar
    
    var onSelect: ((Int) -> Void)?
    var onToggleMode: (() -> Void)?
    var onMark: ((Int) -> Void)?
    var onQuit: (() -> Void)?
    var onAction: ((AppAction) -> Void)? // For first/last
    
    override var acceptsFirstResponder: Bool { true }
    
    private var cellSize: CGFloat { CGFloat(thumbnailSize) + padding * 2 }
    private var columns: Int { max(1, Int(bounds.width / cellSize)) }
    private var rows: Int { files.isEmpty ? 0 : Int(ceil(Double(files.count) / Double(columns))) }

    // Layout reserves: top margin, bottom status bar + filename label + gap.
    private var topPad: CGFloat { 10 }
    private var labelHeight: CGFloat { 14 }
    private var labelGap: CGFloat { 6 }
    private var barHeight: CGFloat { 22 }
    private var bottomReserve: CGFloat { barHeight + labelGap + labelHeight }
    
    func updateFrameHeight() {
        let totalHeight = CGFloat(rows) * cellSize + topPad + bottomReserve
        frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(totalHeight, enclosingScrollView?.contentView.bounds.height ?? 600))
    }
    
    func cellRect(for index: Int) -> NSRect {
        let col = index % columns
        let row = index / columns
        let x = padding + CGFloat(col) * cellSize
        let y = frame.height - topPad - CGFloat(row + 1) * cellSize
        return NSRect(x: x, y: y, width: CGFloat(thumbnailSize), height: CGFloat(thumbnailSize))
    }

    func labelRect(forCell rect: NSRect) -> NSRect {
        NSRect(x: rect.origin.x - padding / 2,
               y: rect.origin.y - labelGap - labelHeight,
               width: cellSize, height: labelHeight)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0).setFill()
        ctx.fill(bounds)
        
        let visibleRect = self.visibleRect
        
        for i in 0..<files.count {
            let rect = cellRect(for: i)
            guard rect.intersects(visibleRect) else { continue }
            
            let file = files[i]
            let isSelected = (i == selectedIndex)
            let isMarked = markedFiles.contains(file)
            
            let cellBg = isSelected ? NSColor.systemBlue.withAlphaComponent(0.3) : NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
            cellBg.setFill()
            ctx.fill(rect.insetBy(dx: -padding/2, dy: -padding/2))
            
            if isSelected {
                NSColor.systemBlue.setStroke()
                ctx.setLineWidth(2.5)
                ctx.stroke(rect.insetBy(dx: -1, dy: -1))
            }
            if isMarked {
                NSColor.systemGreen.setStroke()
                ctx.setLineWidth(2.0)
                ctx.stroke(rect.insetBy(dx: -3, dy: -3))
            }
            
            if let thumb = thumbnails[i] {
                let thumbSize = CGSize(width: thumb.width, height: thumb.height)
                let scale = min(CGFloat(thumbnailSize) / thumbSize.width, CGFloat(thumbnailSize) / thumbSize.height)
                let drawSize = CGSize(width: thumbSize.width * scale, height: thumbSize.height * scale)
                let drawRect = NSRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
                ctx.draw(thumb, in: drawRect)
            } else {
                NSColor.darkGray.setFill()
                ctx.fill(rect)
                if !pendingRequests.contains(i) {
                    pendingRequests.insert(i)
                    requestThumbnail(index: i)
                }
            }
            
            // Draw filename or thumb-info (sits above the status bar)
            let nameText = thumbInfoCache[file.path] ?? file.lastPathComponent
            let nameRect = labelRect(forCell: rect)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: isSelected ? NSColor.white : NSColor.lightGray
            ]
            (nameText as NSString).draw(in: nameRect, withAttributes: attrs)
        }
        
        // --- Draw Status Bar (or red confirm bar) ---
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
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let textSize = (infoText as NSString).size(withAttributes: textAttrs)
        let textRect = NSRect(x: 8, y: (barHeight - textSize.height) / 2, width: bounds.width - 16, height: textSize.height)
        (infoText as NSString).draw(in: textRect, withAttributes: textAttrs)
    }
    
    private func requestThumbnail(index: Int) {
        let file = files[index]
        if let cached = ThumbnailCache.shared.cachedThumbnail(for: file) {
            thumbnails[index] = cached
            pendingRequests.remove(index)
            needsDisplay = true
            return
        }
        ThumbnailCache.shared.generateAndCache(for: file, maxSize: thumbnailSize) { [weak self] img in
            guard let self = self else { return }
            self.thumbnails[index] = img
            self.pendingRequests.remove(index)
            self.needsDisplay = true
        }
    }
    
    func preloadVisible() {
        let visibleRect = self.visibleRect
        let expanded = visibleRect.insetBy(dx: -cellSize * 2, dy: -cellSize * 2)
        for i in 0..<files.count {
            let rect = cellRect(for: i)
            if rect.intersects(expanded) {
                if thumbnails[i] == nil && !pendingRequests.contains(i) {
                    pendingRequests.insert(i)
                    requestThumbnail(index: i)
                }
                // Preload thumb-info
                let file = files[i]
                if thumbInfoCache[file.path] == nil {
                    ScriptRunner.runScript(name: "thumb-info", arguments: [file.path]) { [weak self] output in
                        guard let self = self else { return }
                        self.thumbInfoCache[file.path] = output ?? file.lastPathComponent
                        self.needsDisplay = true
                    }
                }
            }
        }
    }
    
    func selectAndScroll(to index: Int) {
        guard index >= 0, index < files.count else { return }
        selectedIndex = index
        scrollToSelected()
        needsDisplay = true
    }

    /// Indices shifted after a delete — drop index-keyed caches and reload.
    func didDeleteFiles() {
        thumbnails.removeAll()
        pendingRequests.removeAll()
        updateFrameHeight()
        preloadVisible()
        needsDisplay = true
    }
    
    private func scrollToSelected() {
        let rect = cellRect(for: selectedIndex)
        let expanded = rect.insetBy(dx: -cellSize, dy: -cellSize)
        _ = scrollToVisible(expanded)
    }
    
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updateFrameHeight()
        needsDisplay = true
    }
    
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        preloadVisible()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // Bottom strip is the status bar: drag it to move the window.
        if point.y < barHeight {
            movingWindow = true
            (window as? AppWindow)?.beginMoveDrag()
            return
        }
        movingWindow = false
        for i in 0..<files.count {
            if cellRect(for: i).contains(point) {
                selectAndScroll(to: i)
                break
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if movingWindow {
            (window as? AppWindow)?.continueMoveDrag()
        }
    }

    override func mouseUp(with event: NSEvent) {
        movingWindow = false
        (window as? AppWindow)?.endMoveDrag()
    }
    
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
        case 123: moveSelection(by: -1)
        case 124: moveSelection(by: 1)
        case 126: moveSelection(by: -columns)
        case 125: moveSelection(by: columns)
        case 36:  onSelect?(selectedIndex)
        default:
            if let key = chars.first {
                switch key {
                case "h": moveSelection(by: -1)
                case "l": moveSelection(by: 1)
                case "k": moveSelection(by: -columns)
                case "j": moveSelection(by: columns)
                case "t": onToggleMode?()
                case "x": onMark?(selectedIndex)
                case "d": onAction?(.deleteRequest)
                case "c": onAction?(.copyPath)
                case "o": onAction?(.openExternal)
                case "q": onQuit?()
                case "f": onAction?(.toggleFullscreen)
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
    
    private func moveSelection(by delta: Int) {
        let newIndex = selectedIndex + delta
        guard newIndex >= 0, newIndex < files.count else { return }
        selectAndScroll(to: newIndex)
    }
}
