import Foundation

/// Shared atomic-write helper for `~/.bough/<relativePath>` JSON files (D-04).
///
/// Encapsulates the directory-create + encoder-config + atomic-write pattern that
/// was duplicated inline in `Sources/Bough/SessionPersistence.swift`. Lives in
/// `BoughCore` so non-Bough targets (e.g. `UsageDailyAccumulator`) can call it
/// without importing the `Bough` executable target.
///
/// `write` throws so callers can decide whether to surface or swallow errors
/// (SessionPersistence swallows to preserve pre-existing silent-on-error semantics;
/// UsageDailyAccumulator surfaces them up). `read` returns nil on missing-file or
/// decode failure to match the existing `SessionPersistence.load() -> []` contract.
public enum AtomicJSONStore {
    /// Encode `value` as JSON and atomically write it to `~/.bough/<relativePath>`.
    ///
    /// - Foundation's `Data.WritingOptions.atomic` performs the `.tmp + rename`
    ///   dance internally, satisfying the D-04 atomicity invariant.
    /// - Creates `~/.bough/` with intermediate directories if it does not exist.
    /// - Default `dateEncodingStrategy` is `.iso8601` to match the pre-existing
    ///   `SessionPersistence.save` encoder configuration.
    public static func write<T: Encodable>(
        _ value: T,
        to relativePath: String,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601
    ) throws {
        let dirURL = baseDirectoryURL()
        try BoughPrivateStorage.ensurePrivateDirectory(at: dirURL)
        let fileURL = dirURL.appendingPathComponent(relativePath)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        try BoughPrivateStorage.protectPrivateFile(at: fileURL)
    }

    /// Decode JSON from `~/.bough/<relativePath>` into `type`.
    ///
    /// Returns `nil` when the file is absent or the decode fails. This matches
    /// the pre-existing `SessionPersistence.load() -> []` semantics — callers
    /// can substitute their own empty default.
    public static func read<T: Decodable>(
        _ type: T.Type,
        from relativePath: String,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601
    ) -> T? {
        let fileURL = baseDirectoryURL().appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return try? decoder.decode(type, from: data)
    }

    public static func delete(_ relativePath: String) throws {
        let fileURL = baseDirectoryURL().appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Resolve `~/.bough/`.
    ///
    /// We deliberately do NOT use `FileManager.homeDirectoryForCurrentUser` because on
    /// macOS it calls `getpwuid()`, which caches the user record at first use and
    /// ignores subsequent `setenv("HOME", ...)` overrides. Tests rely on `$HOME`
    /// indirection so they can redirect writes to a temp scratch directory; reading
    /// `getenv("HOME")` directly preserves that ability while keeping the public
    /// surface free of test-only init parameters.
    static func baseDirectoryURL() -> URL {
        let homePath: String
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            homePath = envHome
        } else {
            // Fallback: NSHomeDirectory reflects the resolved login user's home and
            // is safe for production callers that never override HOME.
            homePath = NSHomeDirectory()
        }
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".bough", isDirectory: true)
    }
}
