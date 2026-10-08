import AppKit
import Foundation

struct AppConfig {
    var thumbnailSize: Int = 128
    var zoomIncrement: Double = 1.25
    var backgroundColor: String = "#282828"
    var statusBar: Bool = true
    var sortBy: String = "name" // name | date | size
    var recursive: Bool = false
    var slideshowDelay: Double = 3.0 // seconds
    
    var nsBackgroundColor: NSColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
    
    init() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/msxiv/config").path
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let content = String(data: data, encoding: .utf8) else { return }
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            
            let parts = trimmed.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            
            switch parts[0] {
            case "thumbnail_size": thumbnailSize = Int(parts[1]) ?? 128
            case "zoom_increment": zoomIncrement = Double(parts[1]) ?? 1.25
            case "background_color": 
                backgroundColor = parts[1]
                parseHexColor(parts[1])
            case "status_bar": statusBar = parts[1].lowercased() == "true"
            case "sort_by":
                let v = parts[1].lowercased()
                sortBy = ["name", "date", "size"].contains(v) ? v : "name"
            case "recursive": recursive = parts[1].lowercased() == "true"
            case "slideshow_delay":
                slideshowDelay = min(30, max(0.5, Double(parts[1]) ?? 3.0))
            default: break
            }
        }
    }
    
    private mutating func parseHexColor(_ hex: String) {
        var cString = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cString.hasPrefix("#") { cString.removeFirst() }
        guard cString.count == 6 else { return }
        
        var rgbValue: UInt64 = 0
        Scanner(string: cString).scanHexInt64(&rgbValue)
        
        nsBackgroundColor = NSColor(
            calibratedRed: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
