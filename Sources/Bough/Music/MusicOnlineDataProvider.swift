import AppKit
import Foundation

/// The ONLY file in the music module allowed to perform network I/O.
/// Requests carry nothing beyond title/artist/album/duration needed for matching.
/// Responses are cached in memory only; errors are silent.
protocol MusicOnlineHTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionMusicHTTPClient: MusicOnlineHTTPRequesting {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, httpResponse)
    }
}

protocol MusicOnlineDataProviding: Sendable {
    func timedLyrics(for key: MusicTrackMatchKey, durationHint: TimeInterval?) async -> MusicTimedLyrics?
    func artworkData(for key: MusicTrackMatchKey, player: MusicAllowedPlayer?, rawTitle: String?, rawArtist: String?, rawAlbum: String?, durationHint: TimeInterval?) async -> Data?
}

actor MusicOnlineDataProvider: MusicOnlineDataProviding {
    static let negativeCacheInterval: TimeInterval = 600
    static let maxCachedTracks = 50
    static let maxArtworkBytes = 2 * 1024 * 1024
    static let durationTolerance: TimeInterval = 3

    private struct LyricsCacheKey: Hashable {
        let track: MusicTrackMatchKey
        let durationBucket: Int?
    }
    private struct ArtworkCacheKey: Hashable {
        let track: MusicTrackMatchKey
        let player: MusicAllowedPlayer?
        let durationBucket: Int?
    }
    private static func durationBucket(_ hint: TimeInterval?) -> Int? {
        hint.map { Int($0.rounded()) }
    }

    private let http: MusicOnlineHTTPRequesting
    private let qqLocalLibrary: QQMusicLocalLibrary
    private let now: () -> Date

    private var lyricsCache: [LyricsCacheKey: MusicTimedLyrics] = [:]
    private var lyricsCacheOrder: [LyricsCacheKey] = []
    private var lyricsMissedAt: [LyricsCacheKey: Date] = [:]
    private var inFlightLyrics: [LyricsCacheKey: Task<MusicTimedLyrics?, Never>] = [:]

    private var artworkCache: [ArtworkCacheKey: Data] = [:]
    private var artworkCacheOrder: [ArtworkCacheKey] = []
    private var artworkMissedAt: [ArtworkCacheKey: Date] = [:]
    private var inFlightArtwork: [ArtworkCacheKey: Task<Data?, Never>] = [:]

    init(http: MusicOnlineHTTPRequesting = URLSessionMusicHTTPClient(),
         qqLocalLibrary: QQMusicLocalLibrary = QQMusicLocalLibrary(),
         now: @escaping () -> Date = Date.init) {
        self.http = http
        self.qqLocalLibrary = qqLocalLibrary
        self.now = now
    }

    func timedLyrics(for key: MusicTrackMatchKey, durationHint: TimeInterval?) async -> MusicTimedLyrics? {
        let cacheKey = LyricsCacheKey(track: key, durationBucket: Self.durationBucket(durationHint))
        if let cached = lyricsCache[cacheKey] { touch(cacheKey, in: &lyricsCacheOrder); return cached }
        if let missedAt = lyricsMissedAt[cacheKey], now().timeIntervalSince(missedAt) < Self.negativeCacheInterval { return nil }
        if let task = inFlightLyrics[cacheKey] { return await task.value }
        let task = Task { await self.fetchLyrics(for: key, durationHint: durationHint) }
        inFlightLyrics[cacheKey] = task
        let result = await task.value
        inFlightLyrics[cacheKey] = nil
        if let result { insert(result, into: &lyricsCache, order: &lyricsCacheOrder, key: cacheKey); lyricsMissedAt[cacheKey] = nil }
        else { lyricsMissedAt[cacheKey] = now() }
        return result
    }

    private func fetchLyrics(for key: MusicTrackMatchKey, durationHint: TimeInterval?) async -> MusicTimedLyrics? {
        if let song = await qqSearch(key: key, durationHint: durationHint), let songmid = song.songmid,
           let raw = await qqLyricText(songmid: songmid), let lyrics = Self.timedLyrics(fromRawText: raw) { return lyrics }
        if let song = await netEaseSearch(key: key, durationHint: durationHint),
           let raw = await netEaseLyricText(songID: song.id), let lyrics = Self.timedLyrics(fromRawText: raw) { return lyrics }
        return nil
    }

    static func timedLyrics(fromRawText raw: String) -> MusicTimedLyrics? {
        if let timed = MusicTimedLyrics.parsingLRC(raw) { return timed }
        guard let line = MusicLyricsBoundary.oneLine(from: [MusicLyricCandidate(text: raw, source: .boughOnlineSearch)]) else { return nil }
        return MusicTimedLyrics(lines: [MusicTimedLyricLine(offset: 0, text: line)])
    }

    func artworkData(for key: MusicTrackMatchKey, player: MusicAllowedPlayer?, rawTitle: String?, rawArtist: String?, rawAlbum: String?, durationHint: TimeInterval?) async -> Data? {
        let cacheKey = ArtworkCacheKey(track: key, player: player, durationBucket: Self.durationBucket(durationHint))
        if let cached = artworkCache[cacheKey] { touch(cacheKey, in: &artworkCacheOrder); return cached }
        if let missedAt = artworkMissedAt[cacheKey], now().timeIntervalSince(missedAt) < Self.negativeCacheInterval { return nil }
        if let task = inFlightArtwork[cacheKey] { return await task.value }
        let task = Task { await self.fetchArtwork(for: key, player: player, rawTitle: rawTitle, rawArtist: rawArtist, rawAlbum: rawAlbum, durationHint: durationHint) }
        inFlightArtwork[cacheKey] = task
        let result = await task.value
        inFlightArtwork[cacheKey] = nil
        if let result { insert(result, into: &artworkCache, order: &artworkCacheOrder, key: cacheKey); artworkMissedAt[cacheKey] = nil }
        else { artworkMissedAt[cacheKey] = now() }
        return result
    }

    private func fetchArtwork(for key: MusicTrackMatchKey, player: MusicAllowedPlayer?, rawTitle: String?, rawArtist: String?, rawAlbum: String?, durationHint: TimeInterval?) async -> Data? {
        if player == .qqMusic, let albumMid = await qqLocalLibrary.albumMid(title: rawTitle, artist: rawArtist, album: rawAlbum),
           let data = await downloadArtwork(fromTemplatesFor: albumMid) { return data }
        if let song = await qqSearch(key: key, durationHint: durationHint), let albumMid = song.albummid, !albumMid.isEmpty,
           let data = await downloadArtwork(fromTemplatesFor: albumMid) { return data }
        if let song = await netEaseSearch(key: key, durationHint: durationHint),
           let picUrl = await netEasePicURL(songID: song.id), let data = await downloadValidatedImage(from: picUrl) { return data }
        return nil
    }

    private func downloadArtwork(fromTemplatesFor albumMid: String) async -> Data? {
        let urls = [
            "https://y.qq.com/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000",
            "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg?max_age=2592000",
        ].compactMap(URL.init(string:))
        for url in urls { if let data = await downloadValidatedImage(from: url) { return data } }
        return nil
    }

    private func downloadValidatedImage(from url: URL) async -> Data? {
        guard url.scheme == "https", let host = url.host,
              [".qq.com", ".gtimg.cn", ".music.126.net"].contains(where: { host.hasSuffix($0) })
        else { return nil }
        guard let (data, response) = try? await http.data(for: URLRequest(url: url)),
              response.statusCode == 200, !data.isEmpty, data.count <= Self.maxArtworkBytes, NSImage(data: data) != nil
        else { return nil }
        return data
    }

    private struct QQSearchSong: Decodable {
        struct Singer: Decodable { let name: String? }
        let songmid: String?; let songname: String?; let singer: [Singer]?; let albummid: String?; let interval: Double?
    }
    private struct QQSearchResponse: Decodable {
        struct DataBox: Decodable { let song: SongBox? }
        struct SongBox: Decodable { let list: [QQSearchSong]? }
        let data: DataBox?
    }
    private func qqSearch(key: MusicTrackMatchKey, durationHint: TimeInterval?) async -> QQSearchSong? {
        var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "n", value: "10"),
            URLQueryItem(name: "p", value: "1"), URLQueryItem(name: "t", value: "0"), URLQueryItem(name: "cr", value: "1"),
            URLQueryItem(name: "w", value: "\(key.title) \(key.artist)".trimmingCharacters(in: .whitespaces)),
        ]
        guard let url = components.url, let (data, response) = try? await http.data(for: URLRequest(url: url)),
              response.statusCode == 200, let decoded = try? JSONDecoder().decode(QQSearchResponse.self, from: data) else { return nil }
        return (decoded.data?.song?.list ?? []).first { song in
            Self.matches(title: song.songname, artistNames: (song.singer ?? []).compactMap(\.name), duration: song.interval, key: key, durationHint: durationHint)
        }
    }
    private struct QQLyricResponse: Decodable { let retcode: Int?; let lyric: String? }
    private func qqLyricText(songmid: String) async -> String? {
        var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        components.queryItems = [
            URLQueryItem(name: "songmid", value: songmid), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nobase64", value: "0"), URLQueryItem(name: "g_tk", value: "5381"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(QQLyricResponse.self, from: data), decoded.retcode == 0,
              let base64 = decoded.lyric, let lyricData = Data(base64Encoded: base64),
              let text = String(data: lyricData, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    private struct NetEaseSong: Decodable {
        struct Artist: Decodable { let name: String? }
        struct Album: Decodable { let id: Int?; let name: String? }
        let id: Int; let name: String?; let artists: [Artist]?; let album: Album?; let duration: Double?
    }
    private struct NetEaseSearchResponse: Decodable {
        struct Result: Decodable { let songs: [NetEaseSong]? }
        let result: Result?
    }
    private func netEaseSearch(key: MusicTrackMatchKey, durationHint: TimeInterval?) async -> NetEaseSong? {
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [
            URLQueryItem(name: "s", value: "\(key.title) \(key.artist)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "offset", value: "0"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(NetEaseSearchResponse.self, from: data) else { return nil }
        return (decoded.result?.songs ?? []).first { song in
            Self.matches(title: song.name, artistNames: (song.artists ?? []).compactMap(\.name), duration: song.duration.map { $0 / 1_000 }, key: key, durationHint: durationHint)
        }
    }
    private struct NetEaseLyricResponse: Decodable {
        struct LRC: Decodable { let lyric: String? }
        let lrc: LRC?
    }
    private func netEaseLyricText(songID: Int) async -> String? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songID)&lv=1&kv=1&tv=-1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(NetEaseLyricResponse.self, from: data),
              let text = decoded.lrc?.lyric, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private struct NetEaseDetailResponse: Decodable {
        struct Song: Decodable { struct Album: Decodable { let picUrl: String? }; let album: Album? }
        let songs: [Song]?
    }
    private func netEasePicURL(songID: Int) async -> URL? {
        guard let url = URL(string: "https://music.163.com/api/song/detail?id=\(songID)&ids=%5B\(songID)%5D") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await http.data(for: request), response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(NetEaseDetailResponse.self, from: data),
              let pic = decoded.songs?.first?.album?.picUrl else { return nil }
        return URL(string: pic)
    }

    static func matches(title: String?, artistNames: [String], duration: TimeInterval?, key: MusicTrackMatchKey, durationHint: TimeInterval?) -> Bool {
        let candidateTitle = MusicTrackMatchKey.normalize(title)
        guard !candidateTitle.isEmpty, candidateTitle == key.title || candidateTitle.contains(key.title) else { return false }
        if !key.artist.isEmpty {
            let candidateArtist = MusicTrackMatchKey.normalize(artistNames.joined(separator: " "))
            guard !candidateArtist.isEmpty, candidateArtist.contains(key.artist) || key.artist.contains(candidateArtist) else { return false }
        }
        if let durationHint, let duration { guard abs(durationHint - duration) <= durationTolerance else { return false } }
        return true
    }

    private func touch<K: Hashable>(_ key: K, in order: inout [K]) {
        if let index = order.firstIndex(of: key) { order.remove(at: index); order.append(key) }
    }
    private func insert<K: Hashable, Value>(_ value: Value, into cache: inout [K: Value], order: inout [K], key: K) {
        if cache[key] == nil { order.append(key) } else { touch(key, in: &order) }
        cache[key] = value
        while order.count > Self.maxCachedTracks { let evicted = order.removeFirst(); cache[evicted] = nil }
    }
}
