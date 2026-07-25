import Foundation

enum Log {
    static var verbose = ProcessInfo.processInfo.environment["DOUBAO_VERBOSE"] != nil

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ level: String, _ msg: String) {
        FileHandle.standardError.write(
            Data("[\(fmt.string(from: Date()))] \(level) \(msg)\n".utf8))
    }

    static func debug(_ m: @autoclosure () -> String) { if verbose { emit("·", m()) } }
    static func info(_ m: String)  { emit("ℹ", m) }
    static func warn(_ m: String)  { emit("⚠", m) }
    static func error(_ m: String) { emit("✖", m) }
}
