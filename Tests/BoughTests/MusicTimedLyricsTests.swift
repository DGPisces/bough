import Foundation
import XCTest
@testable import Bough

final class MusicTimedLyricsTests: XCTestCase {
    func testParsesSimpleLRC() throws {
        let lrc = """
        [ar:Artist]
        [00:01.00]first line
        [00:12.50]second line

        [01:03]third line
        """
        let lyrics = try XCTUnwrap(MusicTimedLyrics.parsingLRC(lrc))
        XCTAssertEqual(lyrics.lines.map(\.text), ["first line", "second line", "third line"])
        XCTAssertEqual(lyrics.lines[0].offset, 1.0, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[1].offset, 12.5, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[2].offset, 63.0, accuracy: 0.001)
    }

    func testParsesMultipleTagsOnOneLineAndSortsByOffset() throws {
        let lrc = "[00:30.00][00:10.00]chorus"
        let lyrics = try XCTUnwrap(MusicTimedLyrics.parsingLRC(lrc))
        XCTAssertEqual(lyrics.lines.map(\.offset), [10.0, 30.0])
        XCTAssertEqual(lyrics.lines.map(\.text), ["chorus", "chorus"])
    }

    func testReturnsNilForPlainTextWithoutTags() {
        XCTAssertNil(MusicTimedLyrics.parsingLRC("just plain lyrics\nno timestamps"))
    }

    func testCurrentLinePicksLastLineAtOrBeforeElapsed() throws {
        let lyrics = try XCTUnwrap(MusicTimedLyrics.parsingLRC("[00:10]a\n[00:20]b"))
        XCTAssertNil(lyrics.currentLine(at: 5))
        XCTAssertEqual(lyrics.currentLine(at: 10), "a")
        XCTAssertEqual(lyrics.currentLine(at: 19.9), "a")
        XCTAssertEqual(lyrics.currentLine(at: 25), "b")
    }
}
