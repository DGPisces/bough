import AppKit
import Foundation
import SQLite3

actor QQMusicArtworkResolver {
    private static let maxArtworkBytes = 2 * 1024 * 1024
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let databaseRelativePath = "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/qqmusic.sqlite"
    private static let albumMidQuery = """
        SELECT K_SONG_RESERVE9, album
        FROM SONGS
        WHERE K_SONG_RESERVE9 <> ''
          AND name = ? COLLATE NOCASE
          AND (? = '' OR singer = ? COLLATE NOCASE)
        ORDER BY id DESC
        LIMIT 25
        """

    private let session: URLSession
    private let databaseURL: URL
    private let now: () -> Date
    private var artworkCache: [String: Data] = [:]
    private var albumMidCache: [AlbumLookupKey: String] = [:]
    private var albumMidMissCache: [AlbumLookupKey: AlbumLookupMiss] = [:]
    private var failedAlbumMids: Set<String> = []

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(QQMusicArtworkResolver.databaseRelativePath),
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.5
        session = URLSession(configuration: configuration)
    }

    /// Internal lookup used by tests (and later by the online provider).
    func albumMid(title: String?, artist: String?, album: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return cachedAlbumMid(title: title, artist: artist, album: album)
    }

    func artworkData(for payload: MusicNowPlayingPayload) async -> Data? {
        guard MusicAllowedPlayer.match(bundleIdentifier: payload.bundleIdentifier, displayName: payload.displayName) == .qqMusic,
              let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let albumMid = cachedAlbumMid(title: title, artist: payload.artist, album: payload.album),
              !failedAlbumMids.contains(albumMid)
        else {
            return nil
        }

        if let cached = artworkCache[albumMid] {
            return cached
        }

        for url in artworkURLs(albumMid: albumMid) {
            if let data = await fetchArtwork(from: url) {
                artworkCache[albumMid] = data
                return data
            }
        }

        failedAlbumMids.insert(albumMid)
        return nil
    }

    private func cachedAlbumMid(title: String, artist: String?, album: String?) -> String? {
        let key = AlbumLookupKey(title: title, artist: artist, album: album)
        if let cached = albumMidCache[key] {
            return cached
        }

        let databaseModificationDate = Self.databaseModificationDate(for: databaseURL)

        if let miss = albumMidMissCache[key],
           miss.databaseModificationDate == databaseModificationDate,
           now().timeIntervalSince(miss.recordedAt) < Self.missRetryInterval {
            return nil
        }

        guard let resolved = albumMid(
            title: title,
            artist: artist,
            album: album,
            databaseURL: databaseURL
        ) else {
            albumMidMissCache[key] = AlbumLookupMiss(
                databaseModificationDate: databaseModificationDate,
                recordedAt: now()
            )
            return nil
        }
        albumMidMissCache[key] = nil
        albumMidCache[key] = resolved
        return resolved
    }

    private func albumMid(title: String, artist: String?, album: String?, databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else {
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.albumMidQuery, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let artistValue = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sqlite3_bind_text(statement, 1, title, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 2, artistValue, -1, Self.transientDestructor)
        sqlite3_bind_text(statement, 3, artistValue, -1, Self.transientDestructor)

        let requestedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstAlbumMid: String?
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            if let albumMidPointer = sqlite3_column_text(statement, 0) {
                let candidateAlbumMid = String(cString: albumMidPointer)
                if Self.isValidAlbumMid(candidateAlbumMid) {
                    if firstAlbumMid == nil {
                        firstAlbumMid = candidateAlbumMid
                    }

                    let storedAlbum = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                    if Self.albumMatches(requestedAlbum: requestedAlbum, storedAlbum: storedAlbum) {
                        return candidateAlbumMid
                    }
                }
            }
            stepStatus = sqlite3_step(statement)
        }

        guard stepStatus == SQLITE_DONE else { return nil }
        return firstAlbumMid
    }

    private static func databaseModificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func artworkURLs(albumMid: String) -> [URL] {
        [
            "https://y.qq.com/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000",
            "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000",
        ].compactMap(URL.init(string:))
    }

    private func fetchArtwork(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty,
                  data.count <= Self.maxArtworkBytes,
                  NSImage(data: data) != nil
            else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func albumMatches(requestedAlbum: String?, storedAlbum: String?) -> Bool {
        guard let requestedAlbum,
              !requestedAlbum.isEmpty,
              let storedAlbum,
              !storedAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return true
        }

        let requested = requestedAlbum.lowercased()
        let stored = storedAlbum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return requested == stored || requested.contains(stored) || stored.contains(requested)
    }

    private static func isValidAlbumMid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9]{14}$"#, options: .regularExpression) != nil
    }

    private struct AlbumLookupKey: Hashable {
        let title: String
        let artist: String
        let album: String

        init(title: String, artist: String?, album: String?) {
            self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.album = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    static let missRetryInterval: TimeInterval = 600

    private struct AlbumLookupMiss: Equatable {
        let databaseModificationDate: Date?
        let recordedAt: Date
    }
}
