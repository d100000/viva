import Foundation

enum Log {
    static var verbose = ProcessInfo.processInfo.environment["DOUBAO_VERBOSE"] != nil

    static let fileURL = Config.logsDir.appendingPathComponent("viva.log")

    private static let maxFileBytes: UInt64 = 2 * 1024 * 1024
    private static let lock = NSLock()

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ level: String, _ msg: String) {
        lock.lock()
        defer { lock.unlock() }

        let line = Data("[\(fmt.string(from: Date()))] \(level) \(msg)\n".utf8)
        FileHandle.standardError.write(line)
        appendToFile(line)
    }

    private static func appendToFile(_ line: Data) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let attributes = try? fm.attributesOfItem(atPath: fileURL.path)
            if let size = attributes?[.size] as? NSNumber,
               size.uint64Value >= maxFileBytes {
                let previous = dir.appendingPathComponent("viva.previous.log")
                try? fm.removeItem(at: previous)
                try fm.moveItem(at: fileURL, to: previous)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                _ = fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            // 日志落盘失败不能反过来让主业务崩溃；stderr 已保留同一行。
        }
    }

    static func debug(_ m: @autoclosure () -> String) { if verbose { emit("·", m()) } }
    static func info(_ m: String)  { emit("ℹ", m) }
    static func warn(_ m: String)  { emit("⚠", m) }
    static func error(_ m: String) { emit("✖", m) }
}
