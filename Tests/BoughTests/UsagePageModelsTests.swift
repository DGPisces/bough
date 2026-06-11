import XCTest

@testable import Bough
@testable import BoughCore

/// Model tests for the Settings → Usage data-source badge (direct-OAuth
/// channel status, spec §9) and the pace caption rows (spec §8.3).
final class UsagePageModelsTests: XCTestCase {

    // MARK: - UsageOAuthBadgeModel

    private func bracketLocalized(_ key: String) -> String { "[\(key)]" }

    func testBadgeModelUnknownIsOffWithUnknownKeyText() {
        let badge = UsageOAuthBadgeModel(status: .unknown, localized: bracketLocalized)

        XCTAssertEqual(badge.tone, .off)
        XCTAssertEqual(badge.text, "[usage_oauth_badge_unknown]")
    }

    func testBadgeModelConnectedIsOkWithConnectedKeyText() {
        let badge = UsageOAuthBadgeModel(
            status: .connected(at: Date(timeIntervalSince1970: 100)),
            localized: bracketLocalized
        )

        XCTAssertEqual(badge.tone, .ok)
        XCTAssertEqual(badge.text, "[usage_oauth_badge_connected]")
    }

    func testBadgeModelDegradedIsWarningWithReasonPassthrough() {
        // Degraded reasons are pre-localized by UsageStore.degradedReason —
        // the badge must NOT re-localize them.
        let badge = UsageOAuthBadgeModel(
            status: .degraded(reason: "Rate limited — retrying soon", at: Date()),
            localized: bracketLocalized
        )

        XCTAssertEqual(badge.tone, .warning)
        XCTAssertEqual(badge.text, "Rate limited — retrying soon")
    }

    func testBadgeModelMissingCredentialsIsOffWithReasonPassthrough() {
        // Spec §9: no credentials renders gray (off) with login guidance —
        // not the yellow degraded warning.
        let badge = UsageOAuthBadgeModel(
            status: .missingCredentials(reason: "Sign in to Claude Code", at: Date()),
            localized: bracketLocalized
        )

        XCTAssertEqual(badge.tone, .off)
        XCTAssertEqual(badge.text, "Sign in to Claude Code")
    }

    // MARK: - UsagePaceRowModel

    private static let paceStrings: [String: String] = [
        "usage_pace_on_track": "On track",
        "usage_pace_ahead_fmt": "Ahead %d%%",
        "usage_pace_behind_fmt": "Behind %d%%",
        "usage_pace_lasts": "lasts to reset",
        "usage_pace_eta_fmt": "runs out in %@",
    ]

    private func paceLocalized(_ key: String) -> String {
        Self.paceStrings[key] ?? key
    }

    private func weeklyWindow(usedPercent: Double, resetsAt: Date, now: Date) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowDurationMins: 10080,
            sourceLabel: "Codex",
            updatedAt: now
        )
    }

    func testPaceRowAheadMidWindowRendersAheadStageAndEta() {
        // Half of a 7-day window elapsed, 80% used → expected 50, delta +30
        // (farAhead). Burn rate projects exhaustion in exactly 21h.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = weeklyWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(302_400), now: now)

        let model = UsagePaceRowModel(slot: .available(window), now: now, localized: paceLocalized)

        XCTAssertEqual(model.text, "Ahead 30% · runs out in 21h")
    }

    func testPaceRowOnTrackRendersLastsToReset() {
        // Half elapsed, half used → onTrack, budget lasts to the reset.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = weeklyWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(302_400), now: now)

        let model = UsagePaceRowModel(slot: .available(window), now: now, localized: paceLocalized)

        XCTAssertEqual(model.text, "On track · lasts to reset")
    }

    func testPaceRowBehindRendersBehindStage() {
        // Half elapsed, 30% used → delta -20 (farBehind) and lasts to reset.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = weeklyWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(302_400), now: now)

        let model = UsagePaceRowModel(slot: .available(window), now: now, localized: paceLocalized)

        XCTAssertEqual(model.text, "Behind 20% · lasts to reset")
    }

    func testPaceRowIsNilForLoadingSlot() {
        let model = UsagePaceRowModel(
            slot: .loading,
            now: Date(timeIntervalSince1970: 1_000_000),
            localized: paceLocalized
        )

        XCTAssertNil(model.text)
    }

    func testPaceRowIsNilWhenResetIsInThePast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = weeklyWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(-60), now: now)

        let model = UsagePaceRowModel(slot: .available(window), now: now, localized: paceLocalized)

        XCTAssertNil(model.text)
    }

    // MARK: - UsageDetailsModel pace texts

    @MainActor
    func testUsageDetailsModelPopulatesPaceTextsForAvailableWindows() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fiveHour = UsageWindowSnapshot(
            kind: .fiveHour,
            usedPercent: 12,
            resetsAt: now.addingTimeInterval(1_800),
            windowDurationMins: 300,
            sourceLabel: "Codex",
            updatedAt: now
        )
        let weekly = weeklyWindow(usedPercent: 48, resetsAt: now.addingTimeInterval(3_600), now: now)
        let snapshot = UsageSnapshot(
            tool: .codex,
            planName: "pro",
            fiveHour: .available(fiveHour),
            weekly: .available(weekly),
            today: nil,
            availability: .available,
            lastRefresh: now
        )

        let model = UsageDetailsModel(snapshot: snapshot, now: now)

        XCTAssertNotNil(model.fiveHourPaceText)
        XCTAssertNotNil(model.weeklyPaceText)
    }
}
