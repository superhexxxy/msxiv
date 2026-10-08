import Foundation

class ScriptRunner {
    static func runKeyHandler(action: String, files: [URL]) {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/msxiv/key-handler").path
        
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else { return }

        // Never block the main thread on `waitUntilExit()`: a slow or hung
        // user script would freeze the UI. Run on a background queue; these
        // handlers are fire-and-forget (stdin-only, no stdout consumed).
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptPath, action]

            let pipe = Pipe()
            process.standardInput = pipe
            // Don't let a handler that writes lots of stdout deadlock on a
            // full pipe buffer nobody is draining.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let input = files.map { $0.path }.joined(separator: "\n")
                if let data = input.data(using: .utf8) {
                    pipe.fileHandleForWriting.write(data)
                }
                pipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()
            } catch {
                print("msxiv: failed to run key-handler: \(error)")
            }
        }
    }
    
    /// Runs an info/title script in the background and returns its trimmed stdout.
    static func runScript(name: String, arguments: [String], completion: @escaping (String?) -> Void) {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/msxiv/\(name)").path
        
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            completion(nil)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptPath] + arguments
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async { completion(trimmed.isEmpty ? nil : trimmed) }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
