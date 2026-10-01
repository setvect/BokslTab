import Foundation

public enum BokslTabDiagnosticLog {
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BokslTab/BokslTab.log")
    public static var filePath: String { fileURL.path }
    private static let lock = NSLock()
    private static var logger: FileDiagnosticLog?
    private static var includesDebug = false

    /// The app opts in at launch. Library use and tests do not write to the user's log.
    public static func enableFileLogging(includeDebug: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if logger == nil { logger = FileDiagnosticLog(fileURL: fileURL) }
        includesDebug = includeDebug
    }

    public static func write(_ message: @autoclosure () -> String) {
        emit(message, debug: false)
    }

    public static func debug(_ message: @autoclosure () -> String) {
        emit(message, debug: true)
    }

    private static func emit(_ message: () -> String, debug: Bool) {
        lock.lock()
        let destination = debug && !includesDebug ? nil : logger
        lock.unlock()
        destination?.write(message())
    }
}

/// File I/O and the formatter are confined to one queue. Keeps at most two bounded files.
final class FileDiagnosticLog {
    private let queue = DispatchQueue(label: "dev.boksl.BokslTab.logging", qos: .utility)
    private let fileURL: URL
    private let maximumBytes: Int
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?
    private var byteCount = 0

    init(fileURL: URL, maximumBytes: Int = 5 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maximumBytes = max(1, maximumBytes)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit { try? handle?.close() }

    func write(_ message: String) {
        queue.async { self.append(message) }
    }

    func flush() { queue.sync {} }

    private func append(_ message: String) {
        do {
            let manager = FileManager.default
            if handle == nil {
                try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !manager.fileExists(atPath: fileURL.path) {
                    manager.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: fileURL)
                byteCount = Int(try handle!.seekToEnd())
            }
            let data = Data("[\(formatter.string(from: Date()))] \(message)\n".utf8).prefix(maximumBytes)
            if byteCount + data.count > maximumBytes {
                try handle?.close()
                handle = nil
                let previous = fileURL.appendingPathExtension("previous")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                // Discard an oversized legacy log instead of retaining an unbounded archive.
                if byteCount <= maximumBytes { try manager.moveItem(at: fileURL, to: previous) }
                else { try manager.removeItem(at: fileURL) }
                manager.createFile(atPath: fileURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: fileURL)
                byteCount = 0
            }
            try handle?.write(contentsOf: data)
            byteCount += data.count
        } catch {
            try? handle?.close()
            handle = nil
            fputs("BokslTab log write failed: \(error)\n", stderr)
        }
    }
}
