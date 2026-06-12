import Foundation
import XCTest
@testable import Bough

final class MusicOnlineDataProviderTests: XCTestCase {
    private final class StubHTTP: MusicOnlineHTTPRequesting, @unchecked Sendable {
        var routes: [(match: String, body: Data)] = []
        private(set) var requestedURLs: [String] = []
        private let lock = NSLock()

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!.absoluteString
            lock.lock(); requestedURLs.append(url); lock.unlock()
            for route in routes where url.contains(route.match) {
                return (route.body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func makeKey() -> MusicTrackMatchKey { MusicTrackMatchKey(title: "Hello", artist: "Adele", album: "25")! }
    private func nonexistentLibrary() -> QQMusicLocalLibrary { QQMusicLocalLibrary(databaseURL: URL(fileURLWithPath: "/nonexistent")) }

    private static func qqSearchBody(songmid: String = "mid001", albummid: String = "ALB001ALB001AB", interval: Double = 295) -> Data {
        Data("""
        {"data":{"song":{"list":[{"songmid":"\(songmid)","songname":"Hello","singer":[{"name":"Adele"}],"albummid":"\(albummid)","interval":\(interval)}]}}}
        """.utf8)
    }
    private static func qqLyricBody(lrc: String) -> Data {
        let base64 = Data(lrc.utf8).base64EncodedString()
        return Data("{\"retcode\":0,\"lyric\":\"\(base64)\"}".utf8)
    }

    func testFetchesTimedLyricsFromQQ() async {
        let http = StubHTTP()
        http.routes = [
            ("client_search_cp", Self.qqSearchBody()),
            ("fcg_query_lyric_new", Self.qqLyricBody(lrc: "[00:01.00]hello line")),
        ]
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary())
        let lyrics = await provider.timedLyrics(for: makeKey(), durationHint: 295)
        XCTAssertEqual(lyrics?.currentLine(at: 2), "hello line")
        XCTAssertTrue(http.requestedURLs.contains { $0.contains("c.y.qq.com") })
    }

    func testFallsBackToNetEaseWhenQQMisses() async {
        let http = StubHTTP()
        http.routes = [
            ("api/search/get", Data("""
            {"result":{"songs":[{"id":42,"name":"Hello","artists":[{"name":"Adele"}],"album":{"id":7,"name":"25"},"duration":295000}]}}
            """.utf8)),
            ("api/song/lyric", Data(#"{"lrc":{"lyric":"[00:01.00]netease line"}}"#.utf8)),
        ]
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary())
        let lyrics = await provider.timedLyrics(for: makeKey(), durationHint: 295)
        XCTAssertEqual(lyrics?.currentLine(at: 2), "netease line")
    }

    func testRejectsCandidateOutsideDurationTolerance() async {
        let http = StubHTTP()
        http.routes = [("client_search_cp", Self.qqSearchBody(interval: 100))]
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary())
        let lyrics = await provider.timedLyrics(for: makeKey(), durationHint: 295)
        XCTAssertNil(lyrics)
        XCTAssertFalse(http.requestedURLs.contains { $0.contains("fcg_query_lyric_new") }, "不匹配就不该去拉歌词")
    }

    func testNegativeCacheSuppressesRetriesUntilTTL() async {
        let clock = LockedClock(Date(timeIntervalSince1970: 0))
        let http = StubHTTP()
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary(), now: { clock.value })
        _ = await provider.timedLyrics(for: makeKey(), durationHint: nil)
        let firstCount = http.requestedURLs.count
        _ = await provider.timedLyrics(for: makeKey(), durationHint: nil)
        XCTAssertEqual(http.requestedURLs.count, firstCount, "负缓存期内不得重发请求")
        clock.value = Date(timeIntervalSince1970: 601)
        _ = await provider.timedLyrics(for: makeKey(), durationHint: nil)
        XCTAssertGreaterThan(http.requestedURLs.count, firstCount, "TTL 过后允许重试")
    }

    func testPlainTextLyricFallsBackToSingleStaticLine() async {
        let http = StubHTTP()
        http.routes = [
            ("client_search_cp", Self.qqSearchBody()),
            ("fcg_query_lyric_new", Self.qqLyricBody(lrc: "纯文本歌词第一行\n第二行")),
        ]
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary())
        let lyrics = await provider.timedLyrics(for: makeKey(), durationHint: nil)
        XCTAssertEqual(lyrics?.lines.count, 1)
        XCTAssertEqual(lyrics?.currentLine(at: 0), "纯文本歌词第一行")
    }

    func testQQLyricRejectsNonZeroRetcode() async {
        let http = StubHTTP()
        http.routes = [
            ("client_search_cp", Self.qqSearchBody()),
            ("fcg_query_lyric_new", Data(#"{"retcode":-1901,"lyric":""}"#.utf8)),
            ("api/search/get", Data(#"{"result":{"songs":[]}}"#.utf8)),
        ]
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary())
        let lyrics = await provider.timedLyrics(for: makeKey(), durationHint: 295)
        XCTAssertNil(lyrics)
    }

    func testArtworkUsesQQAlbumMidTemplateFromSearch() async {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let png = Data(base64Encoded: pngBase64)!
        let http = StubHTTP()
        http.routes = [
            ("client_search_cp", Self.qqSearchBody(albummid: "ALB001ALB001AB")),
            ("photo_new/T002R300x300M000ALB001ALB001AB", png),
        ]
        let provider = MusicOnlineDataProvider(http: http, qqLocalLibrary: nonexistentLibrary())
        let data = await provider.artworkData(for: makeKey(), player: .spotify, rawTitle: "Hello", rawArtist: "Adele", rawAlbum: "25", durationHint: 295)
        XCTAssertEqual(data, png)
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
