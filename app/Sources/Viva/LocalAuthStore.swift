import Foundation

/// Device-local fallback for builds that do not have an Apple Team ID.
///
/// A traditional macOS Keychain item created by a self-signed build is bound
/// to that build's cdhash. Every rebuild changes the hash and makes macOS ask
/// for the login-keychain password again. This store avoids that prompt while
/// keeping the containing directory private to the current macOS user.
struct LocalAuthStore: Sendable {
    enum StoreError: LocalizedError {
        case unsafePath(String)
        case invalidData
        case valueTooLarge

        var errorDescription: String? {
            switch self {
            case .unsafePath(let path):
                return "本机登录状态路径不安全：\(path)"
            case .invalidData:
                return "本机登录状态文件已损坏"
            case .valueTooLarge:
                return "本机登录状态数据异常"
            }
        }
    }

    private struct Envelope: Codable {
        var version = 1
        var values: [String: Data] = [:]
    }

    private static let maximumFileBytes = 512 * 1024
    private static let maximumValueBytes = 128 * 1024
    private static let maximumEntries = 32

    let directoryURL: URL
    let fileURL: URL

    init(directoryURL: URL, filename: String = "session.json") {
        self.directoryURL = directoryURL
        fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    func read(account: String) throws -> Data? {
        try load().values[account]
    }

    func write(_ data: Data, account: String) throws {
        guard !account.isEmpty, account.utf8.count <= 1024,
              data.count <= Self.maximumValueBytes else {
            throw StoreError.valueTooLarge
        }
        var envelope = try load()
        guard envelope.values[account] != nil
                || envelope.values.count < Self.maximumEntries else {
            throw StoreError.valueTooLarge
        }
        envelope.values[account] = data
        try save(envelope)
    }

    func delete(account: String) throws {
        var envelope = try load()
        guard envelope.values.removeValue(forKey: account) != nil else { return }
        try save(envelope)
    }

    private func load() throws -> Envelope {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return Envelope() }
        try validateDirectory()
        guard fm.fileExists(atPath: fileURL.path) else { return Envelope() }

        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw StoreError.unsafePath(fileURL.path)
        }
        guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
            throw StoreError.valueTooLarge
        }

        let data = try Data(contentsOf: fileURL)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1,
              envelope.values.count <= Self.maximumEntries,
              envelope.values.allSatisfy({
                  !$0.key.isEmpty
                    && $0.key.utf8.count <= 1024
                    && $0.value.count <= Self.maximumValueBytes
              }) else {
            throw StoreError.invalidData
        }
        return envelope
    }

    private func save(_ envelope: Envelope) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumFileBytes else {
            throw StoreError.valueTooLarge
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path)
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directoryURL.path) {
            try validateDirectory()
        } else {
            try fm.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path)

        var directory = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private func validateDirectory() throws {
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw StoreError.unsafePath(directoryURL.path)
        }
    }
}
