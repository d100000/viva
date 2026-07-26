import Foundation
import Darwin

/// 崩溃日志：把致命信号和未捕获的 NSException 落盘到 `~/.config/viva/crashes/`。
///
/// 为什么自己写而不是只靠系统的 .ips 报告：
/// 1. .ips 埋在 `~/Library/Logs/DiagnosticReports/`，普通用户根本找不到，
///    也不知道哪份对应 Viva —— 排障时让用户「把崩溃日志发来」就卡死在这一步。
/// 2. 本项目 ad-hoc 签名、不上 App Store，没有任何崩溃收集通道，
///    用户主动提供的文件是唯一的线索来源。
///
/// ⚠️ 信号处理器里只允许调用 async-signal-safe 函数（open/write/close/backtrace_symbols_fd）。
///   绝不能碰 Swift 的字符串格式化、Data、DateFormatter、malloc —— 崩溃时堆可能已经坏了，
///   在处理器里再触发一次分配就是二次崩溃，连这份日志都留不下来。
///   所以文件路径和头部信息全部在 install() 时预先算好，存成裸 C 缓冲。
enum CrashReporter {

    static let dirURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/viva/crashes", isDirectory: true)

    /// 预计算的崩溃文件路径（C 字符串，处理器里直接用）
    private static var cPath: UnsafeMutablePointer<CChar>?
    /// 预计算的头部（版本、启动时间等，崩溃时原样写入）
    private static var cHeader: UnsafeMutablePointer<CChar>?

    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]

    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        // 文件按「本次启动」命名；只有真崩了才会被创建。
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let name = "crash-\(fmt.string(from: Date()))-pid\(ProcessInfo.processInfo.processIdentifier).log"
        let path = dirURL.appendingPathComponent(name).path

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let header = """
        ==== Viva 崩溃报告 ====
        版本      \(version) (\(build))
        系统      \(os)
        启动时间  \(ISO8601DateFormatter().string(from: Date()))
        运行路径  \(Bundle.main.bundlePath)

        """

        cPath = strdup(path)
        cHeader = strdup(header)

        // NSException（ObjC 异常）—— 不在信号上下文里，可以用正常 Swift
        NSSetUncaughtExceptionHandler { ex in
            CrashReporter.writeException(ex)
        }

        // 致命信号。
        // ⚠️ 实测（macOS 26.5）SA_RESETHAND 并没有把处置复位 —— raise() 后
        //   处理器被再次进入，无限递归写出了 82MB 的日志文件。
        //   所以不依赖任何标志位：处理器入口显式把全部信号复位成 SIG_DFL，
        //   外加一个重入闩（见 signalHandler）。
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = signalHandler
            action.sa_flags = 0
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }

        // 清理 30 天前的旧崩溃文件，防止无限堆积
        pruneOldReports(days: 30)
        Log.info("崩溃日志已启用：\(dirURL.path)")
        if let last = latestReport() {
            Log.warn("发现历史崩溃报告：\(last.lastPathComponent)（设置 → 数据与隐私 → 打开崩溃报告文件夹）")
        }
    }

    /// 最近一次崩溃的文件（给设置页展示「上次崩溃」用）
    static func latestReport() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    // MARK: - 处理器

    /// 重入闩。volatile 语义在这里不重要 —— 同一线程内的递归重入一定看得到新值，
    /// 跨线程同时崩两个的窗口极小，最坏是两份内容交错，不会递归。
    private static var alreadyCrashing: Int32 = 0

    /// ⚠️ async-signal-safe 区域：只有 signal/open/write/close/backtrace/raise
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        // 先把所有信号复位成默认处置 —— 处理器自身再崩（或 raise）都不会回到这里
        signal(SIGSEGV, SIG_DFL); signal(SIGBUS, SIG_DFL); signal(SIGILL, SIG_DFL)
        signal(SIGFPE, SIG_DFL); signal(SIGABRT, SIG_DFL); signal(SIGTRAP, SIG_DFL)
        if CrashReporter.alreadyCrashing != 0 { raise(sig); return }
        CrashReporter.alreadyCrashing = 1

        guard let path = CrashReporter.cPath else { raise(sig); return }
        let fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        if fd >= 0 {
            if let header = CrashReporter.cHeader {
                write(fd, header, strlen(header))
            }
            writeRaw(fd, "信号      ")
            writeSignalName(fd, sig)
            writeRaw(fd, "\n崩溃时间  epoch=")
            writeInt(fd, Int(time(nil)))
            writeRaw(fd, "\n\n---- 调用栈 ----\n")
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
            let n = backtrace(&frames, 128)
            backtrace_symbols_fd(&frames, n, fd)
            writeRaw(fd, "\n(地址需配合同版本二进制用 atos 符号化；系统 .ips 报告在 ~/Library/Logs/DiagnosticReports/)\n")
            close(fd)
        }
        // SA_RESETHAND 已恢复默认处置，重新抛出让系统走完正常崩溃流程
        raise(sig)
    }

    private static func writeException(_ ex: NSException) {
        // 异常报告（带符号名，比信号路径的裸地址好读）已经是完整信息了；
        // 落闩，让随后必然到来的 SIGABRT 不再追加第二份。
        alreadyCrashing = 1
        guard let p = cPath else { return }
        let path = String(cString: p)
        let header = cHeader.map { String(cString: $0) } ?? ""
        let text = """
        \(header)异常      NSException \(ex.name.rawValue)
        原因      \(ex.reason ?? "无")
        崩溃时间  \(ISO8601DateFormatter().string(from: Date()))

        ---- 调用栈 ----
        \(ex.callStackSymbols.joined(separator: "\n"))
        """
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    // MARK: - signal-safe 小工具

    private static func writeRaw(_ fd: Int32, _ s: StaticString) {
        s.withUTF8Buffer { buf in
            if let base = buf.baseAddress { _ = write(fd, base, buf.count) }
        }
    }

    private static func writeSignalName(_ fd: Int32, _ sig: Int32) {
        switch sig {
        case SIGSEGV: writeRaw(fd, "SIGSEGV (段错误)")
        case SIGBUS:  writeRaw(fd, "SIGBUS (总线错误)")
        case SIGILL:  writeRaw(fd, "SIGILL (非法指令)")
        case SIGFPE:  writeRaw(fd, "SIGFPE (算术异常)")
        case SIGABRT: writeRaw(fd, "SIGABRT (abort)")
        case SIGTRAP: writeRaw(fd, "SIGTRAP (断言/Swift 运行时陷阱)")
        default:      writeRaw(fd, "未知信号")
        }
    }

    /// 十进制整数 → ASCII。栈上缓冲，不碰堆 —— Array 的分配在信号上下文里不安全
    private static func writeInt(_ fd: Int32, _ value: Int) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buf in
            var v = max(0, value)
            var i = buf.count
            repeat {
                i -= 1
                buf[i] = UInt8(ascii: "0") + UInt8(v % 10)
                v /= 10
            } while v > 0 && i > 0
            _ = write(fd, buf.baseAddress! + i, buf.count - i)
        }
    }

    private static func pruneOldReports(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.lastPathComponent.hasPrefix("crash-") {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
