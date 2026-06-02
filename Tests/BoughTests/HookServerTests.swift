import XCTest

@testable import Bough
@testable import BoughCore

@MainActor
final class HookServerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        let suiteName = "HookServerTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testHandleQuotaEventAppliesClaudeCodePayloadToUsageStore() {
        let appState = AppState()
        appState.usageStore = UsageStore(
            defaults: defaults,
            scheduler: RecordingHookServerUsageRefreshScheduler(),
            monitorClaudeCode: false,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let server = HookServer(appState: appState)

        XCTAssertTrue(server.handleQuotaEvent(payload: Self.claudePayload()))

        let snapshot = appState.usageStore.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 18)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 32)
        XCTAssertNotNil(snapshot.today)
    }

    private static func claudePayload() -> Data {
        Data(
            """
            {
              "version": 1,
              "model": {"display_name": "Claude Sonnet 4"},
              "rate_limits": {
                "five_hour": {"used_percent": 18, "resets_at": 2800, "window_duration_mins": 300},
                "seven_day": {"used_percent": 32, "resets_at": 100000, "window_duration_mins": 10080}
              }
            }
            """.utf8
        )
    }
}

private final class RecordingHookServerUsageRefreshScheduler: UsageRefreshScheduling {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {}
    func stop() {}
}

private extension UsageWindowSlot {
    var snapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .unavailable: return nil
        }
    }
}
