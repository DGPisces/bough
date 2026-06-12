import Foundation
import XCTest
@testable import Bough

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

final class OSAScriptNowPlayingPayloadReaderTests: XCTestCase {
    private static let validJSON = Data(#"{"title":"Song","artist":"A","playbackRate":1}"#.utf8)
    private static let emptyJSON = Data("{}".utf8)

    func testFailureLadderBacksOff10Then30Then60() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let runCount = LockedBox(0)
        let reader = OSAScriptNowPlayingPayloadReader(
            processRunner: { _, _, _ in runCount.withLock { $0 += 1 }; return Self.emptyJSON },
            now: { clock.withLock { $0 } }
        )
        func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }

        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 1)
        advance(5)
        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 1)
        advance(6)
        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 2)
        advance(29)
        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 2)
        advance(2)
        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 3)
    }

    func testActiveProbeUsesShortIntervalAndDoesNotFightFailureLadder() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let runCount = LockedBox(0)
        let reader = OSAScriptNowPlayingPayloadReader(
            processRunner: { _, _, _ in runCount.withLock { $0 += 1 }; return Self.emptyJSON },
            now: { clock.withLock { $0 } }
        )
        func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }

        _ = await reader.currentPayload(bypassingBackoff: false, probingActivePlayback: true)
        XCTAssertEqual(runCount.withLock { $0 }, 1)
        advance(1)
        _ = await reader.currentPayload(bypassingBackoff: false, probingActivePlayback: true)
        XCTAssertEqual(runCount.withLock { $0 }, 1, "2 秒探针间隔内不得重试")
        advance(1.5)
        _ = await reader.currentPayload(bypassingBackoff: false, probingActivePlayback: true)
        XCTAssertEqual(runCount.withLock { $0 }, 2, "探针间隔过后允许重试，不被 10s 失败梯度拦截")
    }

    func testSuccessResetsBackoffState() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 0))
        let results = LockedBox<[Data?]>([Self.emptyJSON, Self.validJSON, Self.emptyJSON])
        let runCount = LockedBox(0)
        let reader = OSAScriptNowPlayingPayloadReader(
            processRunner: { _, _, _ in
                runCount.withLock { $0 += 1 }
                return results.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            },
            now: { clock.withLock { $0 } }
        )
        func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }

        _ = await reader.currentPayload(bypassingBackoff: false)
        advance(11)
        let payload = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(payload?.title, "Song")
        advance(0.1)
        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 3)
        advance(9)
        _ = await reader.currentPayload(bypassingBackoff: false)
        XCTAssertEqual(runCount.withLock { $0 }, 3)
    }
}
