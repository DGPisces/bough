import Foundation

enum UTF8FileChunkReader {
    static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func tailText(path: String, maxBytes: UInt64) -> String? {
        guard maxBytes > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize = min(fileSize, maxBytes)
        let offset = fileSize - readSize
        let startsAtLineBoundary = isLineBoundary(at: offset, in: handle)

        handle.seek(toFileOffset: offset)
        var text = decode(handle.readDataToEndOfFile())
        if !startsAtLineBoundary {
            text = droppingLeadingLineFragment(from: text)
        }
        return text
    }

    static func headAndTailTexts(path: String, maxBytes: UInt64) -> (head: String, tail: String)? {
        guard maxBytes > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        if fileSize <= maxBytes {
            handle.seek(toFileOffset: 0)
            let text = decode(handle.readDataToEndOfFile())
            return (text, text)
        }

        let half = max(maxBytes / 2, 1)
        handle.seek(toFileOffset: 0)
        var head = decode(handle.readData(ofLength: Int(half)))
        head = droppingTrailingLineFragment(from: head)

        let tailOffset = fileSize - half
        let tailStartsAtLineBoundary = isLineBoundary(at: tailOffset, in: handle)
        handle.seek(toFileOffset: tailOffset)
        var tail = decode(handle.readDataToEndOfFile())
        if !tailStartsAtLineBoundary {
            tail = droppingLeadingLineFragment(from: tail)
        }
        return (head, tail)
    }

    static func headAndTailText(path: String, maxBytes: UInt64) -> String? {
        guard let parts = headAndTailTexts(path: path, maxBytes: maxBytes) else { return nil }
        if parts.head == parts.tail { return parts.head }
        if parts.head.isEmpty { return parts.tail }
        if parts.tail.isEmpty { return parts.head }
        return parts.head + "\n" + parts.tail
    }

    private static func isLineBoundary(at offset: UInt64, in handle: FileHandle) -> Bool {
        guard offset > 0 else { return true }
        handle.seek(toFileOffset: offset - 1)
        return handle.readData(ofLength: 1).first == 0x0A
    }

    private static func droppingLeadingLineFragment(from text: String) -> String {
        guard let firstNewline = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: firstNewline)...])
    }

    private static func droppingTrailingLineFragment(from text: String) -> String {
        guard !text.isEmpty, text.last != "\n" else { return text }
        guard let lastNewline = text.lastIndex(of: "\n") else { return "" }
        return String(text[...lastNewline])
    }
}
