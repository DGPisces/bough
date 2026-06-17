import Foundation
import SQLite3
import XCTest
@testable import Bough

final class QQMusicLocalLibraryTests: XCTestCase {
    private func makeDatabase(rows: [(name: String, singer: String, album: String, mid: String)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qq-test-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let create = "CREATE TABLE SONGS (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, singer TEXT, album TEXT, K_SONG_RESERVE9 TEXT);"
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
        for row in rows {
            let insert = "INSERT INTO SONGS (name, singer, album, K_SONG_RESERVE9) VALUES ('\(row.name)', '\(row.singer)', '\(row.album)', '\(row.mid)');"
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    func testAlbumMidResolvesFromLocalDatabase() async throws {
        let url = try makeDatabase(rows: [("Song A", "Artist A", "Album A", "001MVMWX3Trbpq")])
        let resolver = QQMusicLocalLibrary(databaseURL: url)
        let mid = await resolver.albumMid(title: "Song A", artist: "Artist A", album: "Album A")
        XCTAssertEqual(mid, "001MVMWX3Trbpq")
    }

    func testMissCacheRetriesAfterTTLEvenWhenMtimeUnchanged() async throws {
        let url = try makeDatabase(rows: [])

        // Pin mtime to a whole-second value so setAttributes round-trips survive precision loss.
        let pinnedMtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinnedMtime], ofItemAtPath: url.path)

        var current = Date(timeIntervalSince1970: 1_000)
        let resolver = QQMusicLocalLibrary(databaseURL: url, now: { current })

        let first = await resolver.albumMid(title: "Missing", artist: nil, album: nil)
        XCTAssertNil(first)

        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "INSERT INTO SONGS (name, singer, album, K_SONG_RESERVE9) VALUES ('Missing', '', '', '001MVMWX3Trbpq');", nil, nil, nil)
        sqlite3_close(db)
        // Restore mtime so the cache sees no mtime change.
        try FileManager.default.setAttributes([.modificationDate: pinnedMtime], ofItemAtPath: url.path)

        current = current.addingTimeInterval(60)
        let second = await resolver.albumMid(title: "Missing", artist: nil, album: nil)
        XCTAssertNil(second)

        current = current.addingTimeInterval(600)
        let third = await resolver.albumMid(title: "Missing", artist: nil, album: nil)
        XCTAssertEqual(third, "001MVMWX3Trbpq")
    }

    func testMissCacheInvalidatesImmediatelyWhenMtimeChanges() async throws {
        let url = try makeDatabase(rows: [])
        var current = Date(timeIntervalSince1970: 1_000)
        let resolver = QQMusicLocalLibrary(databaseURL: url, now: { current })
        _ = await resolver.albumMid(title: "Missing", artist: nil, album: nil)

        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "INSERT INTO SONGS (name, singer, album, K_SONG_RESERVE9) VALUES ('Missing', '', '', '001MVMWX3Trbpq');", nil, nil, nil)
        sqlite3_close(db)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: url.path)

        current = current.addingTimeInterval(1)
        let result = await resolver.albumMid(title: "Missing", artist: nil, album: nil)
        XCTAssertEqual(result, "001MVMWX3Trbpq")
    }
}
