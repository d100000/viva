import Foundation
import AppKit

/// 软件更新：读 GitHub Releases 的最新版本，下载 ZIP、原地替换 .app、重启。
///
/// 不用 Sparkle：它要 appcast.xml + EdDSA 签名一整套基建，而本项目「无第三方依赖」。
/// GitHub Releases API 本身就是现成的 feed，ZIP 就是现成的包 —— 少一层东西少一层坑。
///
/// 签名是固定自签证书（make-signing-cert.sh）：DR = certificate leaf，更新前后不变，
/// TCC 的「辅助功能」授权跨更新保留。历史上 ad-hoc 时代每次更新都会掉授权，
/// App 每 2 秒的权限复查 + 引导 UI 就是那时的兜底，现在保留 —— 防证书丢失回退 ad-hoc。
@MainActor
final class UpdateChecker {

    /// 测试钩子：E2E 测试用本地 mock server 替换真实 API
    static var apiURL: String {
        ProcessInfo.processInfo.environment["VIVA_UPDATE_API"]
            ?? "https://api.github.com/repos/d100000/viva/releases/latest"
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release {
        let version: String     // 去掉 v 前缀，如 "0.7.0"
        let zipURL: URL
    }

    enum UpdateError: LocalizedError {
        case noRelease
        case badResponse(String)
        case noZipAsset
        case verifyFailed(String)
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .noRelease: return "仓库还没有发布任何版本"
            case .badResponse(let s): return "检查更新失败：\(s)"
            case .noZipAsset: return "最新 Release 里没有 ZIP 安装包"
            case .verifyFailed(let s): return "下载的更新包校验失败：\(s)"
            case .notWritable(let p): return "没有写入 \(p) 的权限，请手动重跑 install.sh 更新"
            }
        }
    }

    // MARK: - 检查

    /// 返回比当前更新的版本；已是最新返回 nil。
    func checkLatest() async throws -> Release? {
        guard let url = URL(string: Self.apiURL) else { throw UpdateError.badResponse("API 地址非法") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        // 显式 UA：GitHub API 对无 UA 的请求会 403
        req.setValue("Viva/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse("非 HTTP 响应") }
        if http.statusCode == 404 { throw UpdateError.noRelease }
        guard http.statusCode == 200 else { throw UpdateError.badResponse("HTTP \(http.statusCode)") }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw UpdateError.badResponse("响应解析失败")
        }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        guard Self.isNewer(remote, than: Self.currentVersion) else {
            Log.info("检查更新：线上 \(remote)，本机 \(Self.currentVersion)，已是最新")
            return nil
        }

        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: {
            let name = ($0["name"] as? String) ?? ""
            return name.hasPrefix("Viva-") && name.hasSuffix(".zip")
        }), let urlStr = zip["browser_download_url"] as? String,
           let zipURL = URL(string: urlStr) else {
            throw UpdateError.noZipAsset
        }
        Log.info("检查更新：发现新版 \(remote)（本机 \(Self.currentVersion)）")
        return Release(version: remote, zipURL: zipURL)
    }

    /// 纯数字段的语义化比较；位数不齐按 0 补（"0.10.0" > "0.9.9"）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 下载并安装

    /// 全程：下载 → 解压 → 校验版本 → 去隔离 → 原子换包 → 重启。
    /// 成功时本进程会退出（重启），只有失败才会正常返回抛错。
    func downloadAndInstall(_ release: Release, progress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("viva-update-\(release.version)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress("下载 \(release.version)…")
        let (tmpFile, resp) = try await URLSession.shared.download(from: release.zipURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse("下载失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let zipPath = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: tmpFile, to: zipPath)

        progress("解压…")
        let extractDir = work.appendingPathComponent("x")
        try runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path])
        let newApp = extractDir.appendingPathComponent("Viva.app")

        // ── 校验：包结构完整 + 版本号与 Release 一致，防挂错资产/截断的包 ──
        progress("校验…")
        let plistURL = newApp.appendingPathComponent("Contents/Info.plist")
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/Viva").path),
              let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let gotVersion = plist["CFBundleShortVersionString"] as? String else {
            throw UpdateError.verifyFailed("包结构不完整")
        }
        guard gotVersion == release.version else {
            throw UpdateError.verifyFailed("包内版本 \(gotVersion) 与 Release \(release.version) 不符")
        }

        // 去 Gatekeeper 隔离。URLSession 的下载通常不带 quarantine，但防御性地清一次 ——
        // 这一步在 install.sh 和 cask 里都被证明是承重的
        try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // ── 原子换包：现在的 .app 先挪去临时目录（运行中的进程不受影响，
        //    页面早已映射进内存），新包 ditto 进原位，失败则回滚 ──
        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }
        progress("安装…")
        let backup = work.appendingPathComponent("old-Viva.app")
        try fm.moveItem(at: bundleURL, to: backup)
        do {
            try runTool("/usr/bin/ditto", [newApp.path, bundleURL.path])
        } catch {
            try? fm.moveItem(at: backup, to: bundleURL)   // 回滚，老版本原样在
            throw UpdateError.verifyFailed("写入失败已回滚：\(error.localizedDescription)")
        }

        Log.info("更新完成 \(Self.currentVersion) → \(release.version)，重启")
        progress("重启中…")
        relaunch(bundleURL)
    }

    // MARK: -

    private func runTool(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.verifyFailed("\((path as NSString).lastPathComponent) 退出码 \(p.terminationStatus)")
        }
    }

    /// 用外部 shell 延迟 open 新包，本进程立即退出 —— 经典的自更新重启模式
    private func relaunch(_ bundleURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 路径经 shell 单引号包裹（内部单引号转义），中文/空格路径安全
        let quoted = "'" + bundleURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        p.arguments = ["-c", "sleep 1; /usr/bin/open \(quoted)"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
