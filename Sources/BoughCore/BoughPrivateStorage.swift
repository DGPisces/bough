import Foundation

public enum BoughPrivateStorage {
    public static let directoryPermissions = 0o700
    public static let filePermissions = 0o600

    public static func ensurePrivateDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: url.path
        )
    }

    public static func ensurePrivateDirectoryForFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try ensurePrivateDirectory(
            at: url.deletingLastPathComponent(),
            fileManager: fileManager
        )
    }

    public static func protectPrivateFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: url.path
        )
    }

    public static func protectPrivateFileIfPresent(
        atPath path: String,
        fileManager: FileManager = .default
    ) {
        try? protectPrivateFile(at: URL(fileURLWithPath: path), fileManager: fileManager)
    }
}
