import XCTest
@testable import Bough

final class UTF8FileChunkReaderTests: XCTestCase {
    func testTailTextSurvivesOffsetInsideUTF8ScalarAndDropsPartialLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UTF8FileChunkReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("tail.jsonl")
        let prefix = String(repeating: "a", count: 256)
        let completeLine = #"{"type":"message","text":"保留"}"#
        let contents = prefix + "😀\n" + completeLine + "\n"
        let data = Data(contents.utf8)
        try data.write(to: path)

        let offsetInsideEmoji = Data(prefix.utf8).count + 1
        let maxBytes = UInt64(data.count - offsetInsideEmoji)

        let text = try XCTUnwrap(UTF8FileChunkReader.tailText(path: path.path, maxBytes: maxBytes))

        XCTAssertEqual(text, completeLine + "\n")
    }
}
