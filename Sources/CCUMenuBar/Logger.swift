import Foundation
import os

enum Log {
    private static let osLogger = Logger(subsystem: "com.ccu.menubar", category: "app")

    private static let queue = DispatchQueue(label: "ccu.log.file")

    private static let rotateBytes: Int = 1_048_576

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func boot() {
        try? FileManager.default.createDirectory(at: AppPaths.logDirectory, withIntermediateDirectories: true)
        write("boot")
    }

    /// The active log file, for surfacing in Finder.
    static var fileURL: URL { AppPaths.appLogFile }

    static func warn(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        write("warn " + message)
    }

    static func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        write("info " + message)
    }

    static func flush() {
        // synchronous fence so writes drain before terminate
        queue.sync { }
    }

    private static func write(_ line: String) {
        queue.async {
            rotateIfNeeded()
            let stamped = "[\(isoFormatter.string(from: Date()))] \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: AppPaths.appLogFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: AppPaths.appLogFile)
            }
        }
    }

    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: AppPaths.appLogFile.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > rotateBytes else { return }
        try? FileManager.default.removeItem(at: AppPaths.appLogBackupFile)
        try? FileManager.default.moveItem(at: AppPaths.appLogFile, to: AppPaths.appLogBackupFile)
    }
}
