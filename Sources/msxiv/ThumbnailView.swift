import AppKit

class ThumbnailView: NSView {
    var files: [URL] = [] { didSet { labelStrings.removeAll() } }
    var markedFiles: Set<URL> = [] { didSet { setNeedsDisplay() } }
    var selectedIndex: Int = 0
    var thumbnailSize: Int = 128
    var padding: CGFloat = 8
    
    private var thumbnails: [Int: CGImage] = [:]
    private var pendingRequests: Set<Int> = []
    private var movingWindow = false
    var thumbInfoCache: [String: String] = [:] // Cache for thumb-info script output
    
    // Redraws are coalesced via setNeedsDisplay(): changes that land while
    // the view is already dirty skip redundant display-cycle scheduling.
    var statusInfo: String? { didSet { setNeedsDisplay() } }
    var defaultInfo: String = "" { didSet { setNeedsDisplay() } }
    var confirmPrompt: String? { didSet { setNeedsDisplay() } } // When set: red Y/N bar replaces the status bar

    /// Cached attribute dicts: these were rebuilt per cell on every frame.
    private lazy var labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9),
        .foregroundColor: NSColor.lightGray
    ]
    private lazy var labelAttrsSelected: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9),
        .foregroundColor: NSColor.white
    ]
    private lazy var statusAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.white
    ]
    private var cachedStatusLineHeight: CGFloat?
    
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
        cellRect(for: index, columns: columns, cellSize: cellSize)
    }

    /// Fast path for the draw/preload loops: layout constants computed once
    /// per frame and passed in instead of recomputed per cell.
    private func cellRect(for index: Int, columns cols: Int, cellSize cSize: CGFloat) -> NSRect {
        let col = index % cols
        let row = index / cols
        let x = padding + CGFloat(col) * cSize
        let y = frame.height - topPad - CGFloat(row + 1) * cSize
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
        // Snapshot layout values once per frame instead of recomputing the
        // same property-chain math for every cell.
        let nCells = files.count
        let cols = columns
        let cSize = cellSize
        let halfPad = padding / 2
        let tMax = CGFloat(thumbnailSize)

        for i in 0..<nCells {
            let rect = cellRect(for: i, columns: cols, cellSize: cSize)
            guard rect.intersects(visibleRect) else { continue }
            
            let file = files[i]
            let isSelected = (i == selectedIndex)
            let isMarked = markedFiles.contains(file)
            
            let cellBg = isSelected ? NSColor.systemBlue.withAlphaComponent(0.3) : NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
            cellBg.setFill()
            ctx.fill(rect.insetBy(dx: -halfPad, dy: -halfPad))
            
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
                let scale = min(tMax / thumbSize.width, tMax / thumbSize.height)
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
            
            // Draw filename or thumb-info (sits above the status bar).
            // The NSString bridge is memoized; `as NSString` allocates a
            // wrapper on every call otherwise.
            let nameText = labelString(for: file)
            let nameRect = labelRect(forCell: rect)
            nameText.draw(in: nameRect, withAttributes: isSelected ? labelAttrsSelected : labelAttrs)
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
        if cachedStatusLineHeight == nil {
            cachedStatusLineHeight = ("X" as NSString).size(withAttributes: statusAttrs).height
        }
        let lh = cachedStatusLineHeight!
        let textRect = NSRect(x: 8, y: (barHeight - lh) / 2, width: bounds.width - 16, height: lh)
        (infoText as NSString).draw(in: textRect, withAttributes: statusAttrs)
    }

    /// Memoized NSString per file path so each redraw does not re-bridge.
    private var labelStrings: [String: NSString] = [:]
    private func labelString(for file: URL) -> NSString {
        let text = thumbInfoCache[file.path] ?? file.lastPathComponent
        if let cached = labelStrings[file.path], cached as String == text { return cached }
        let ns = text as NSString
        labelStrings[file.path] = ns
        return ns
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
            // File list may have shifted (delete) since the request was made.
            guard index < self.files.count, self.files[index] == file else {
                self.pendingRequests.remove(index)
                return
            }
            self.thumbnails[index] = img
            self.pendingRequests.remove(index)
            // Only invalidate the one cell that changed, not the whole grid.
            if let idx = self.files.firstIndex(of: file), idx == index {
                self.setNeedsDisplay(self.cellRect(for: index))
            } else {
                self.needsDisplay = true
            }
        }
    }
    
    func preloadVisible() {
        let visibleRect = self.visibleRect
        let cSize = cellSize
        let cols = columns
        let expanded = visibleRect.insetBy(dx: -cSize * 2, dy: -cSize * 2)
        let n = files.count
        guard n > 0 else { return }

        // Grid layout is deterministic: compute the first/last row that
        // intersects the expanded rect instead of testing every file. The
        // horizontal span always covers all columns (the expanded rect
        // reaches past both view edges), so no column clipping is needed.
        let topY = frame.height - topPad
        let lastRow = (n - 1) / cols
        let r0 = max(0, min(Int((topY - expanded.maxY) / cSize), lastRow))
        let r1 = max(0, min(Int((topY - expanded.minY) / cSize), lastRow))

        for row in r0...r1 {
            for col in 0..<cols {
                let i = row * cols + col
                if i >= n { break }
                if thumbnails[i] == nil && !pendingRequests.contains(i) {
                    pendingRequests.insert(i)
                    requestThumbnail(index: i)
                }
                // Preload thumb-info
                let file = files[i]
                if thumbInfoCache[file.path] == nil && !pendingThumbInfo.contains(file.path) {
                    pendingThumbInfo.insert(file.path)
                    ScriptRunner.runScript(name: "thumb-info", arguments: [file.path]) { [weak self] output in
                        guard let self = self else { return }
                        self.pendingThumbInfo.remove(file.path)
                        self.thumbInfoCache[file.path] = output ?? file.lastPathComponent
                        self.setNeedsDisplay(self.cellRect(for: i))
                    }
                }
            }
        }
    }

    /// Paths with an in-flight thumb-info script; prevents re-spawning the
    /// same subprocess on every scroll/redraw while a result is pending.
    private var pendingThumbInfo: Set<String> = []
    
    func selectAndScroll(to index: Int) {
        guard index >= 0, index < files.count else { return }
        let oldIndex = selectedIndex
        selectedIndex = index
        scrollToSelected()
        // Only the two changed cells need repainting (scroll may already
        // have queued a redraw of newly exposed areas).
        if oldIndex != index {
            setNeedsDisplay(cellRect(for: oldIndex))
        }
        setNeedsDisplay(cellRect(for: index))
    }

    /// Indices shifted after a delete — drop index-keyed caches and reload.
    func didDeleteFiles() {
        thumbnails.removeAll()
        pendingRequests.removeAll()
        pendingThumbInfo.removeAll()
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
