import XCTest
@testable import Bough
@testable import BoughCore

final class UsageNotificationServiceTests: XCTestCase {
    func testReportsPermissionStatesWithoutPrompting() async {
        let service = UsageNotificationService(client: FakeUsageNotificationClient(status: .denied))

        let state = await service.permissionState()

        XCTAssertEqual(state, .denied)
    }

    func testRequestAccessOnlyRunsForExplicitAction() async {
        let client = FakeUsageNotificationClient(status: .notDetermined, requestedStatus: .authorized)
        let service = UsageNotificationService(client: client)

        XCTAssertEqual(client.requestCount, 0)
        let state = await service.requestAccessForExplicitUserAction()

        XCTAssertEqual(state, .authorized)
        XCTAssertEqual(client.requestCount, 1)
    }

    func testSendNotificationMarksLedgerCreatedWhenAuthorized() async throws {
        let store = try makeStore()
        let edge = recoveryEdge()
        try store.recordRecoveryEdge(edge)
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client, now: { Date(timeIntervalSince1970: 2_500) })

        let result = await service.sendNotificationIfAllowed(for: edge, continuityStore: store)

        XCTAssertEqual(result.permissionState, .authorized)
        XCTAssertEqual(result.notificationIdentifier, "bough.usage-recovery.codex.weekly.weekly:10080:2000")
        XCTAssertEqual(client.sentTitles, ["Codex weekly quota recovered"])
        let record = try XCTUnwrap(store.recoveryEdgeRecords().first)
        XCTAssertEqual(record.reminderIdentifier, "bough.usage-recovery.codex.weekly.weekly:10080:2000")
        XCTAssertEqual(record.firedAt, Date(timeIntervalSince1970: 2_500))
    }

    func testDeniedAndUnavailableDoNotSendNotificationOrFallbackReminder() async throws {
        for state in [UsageNotificationPermissionState.denied, .unavailable] {
            let store = try makeStore()
            let edge = recoveryEdge(resetIntervalID: "weekly:10080:\(state)")
            try store.recordRecoveryEdge(edge)
            let client = FakeUsageNotificationClient(status: state)
            let service = UsageNotificationService(client: client)

            let result = await service.sendNotificationIfAllowed(for: edge, continuityStore: store)

            XCTAssertEqual(result.permissionState, state)
            XCTAssertNil(result.notificationIdentifier)
            XCTAssertEqual(client.sentTitles, [])
            XCTAssertNotNil(try store.recoveryEdgeRecords().first?.errorMessage)
        }
    }

    func testSendFailureIsRecorded() async throws {
        let store = try makeStore()
        let edge = recoveryEdge()
        try store.recordRecoveryEdge(edge)
        let client = FakeUsageNotificationClient(status: .authorized, sendError: TestError.failed)
        let service = UsageNotificationService(client: client)

        let result = await service.sendNotificationIfAllowed(for: edge, continuityStore: store)

        XCTAssertEqual(result.permissionState, .failed("failed"))
        XCTAssertNil(result.notificationIdentifier)
        XCTAssertEqual(try store.recoveryEdgeRecords().first?.errorMessage, "failed")
    }

    func testPendingNotificationsRespectStoredPreference() async throws {
        let store = try makeStore()
        let edge = recoveryEdge()
        try store.recordRecoveryEdge(edge)
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client, now: { Date(timeIntervalSince1970: 2_600) })

        await service.sendPendingNotifications(from: store)
        XCTAssertEqual(client.sentTitles, [])

        try store.setRecoveryReminderPreference(tool: .codex, windowKind: .weekly, isEnabled: true, updatedAt: Date())
        await service.sendPendingNotifications(from: store)

        XCTAssertEqual(client.sentTitles, ["Codex weekly quota recovered"])
        XCTAssertEqual(try store.recoveryEdgeRecords().first?.firedAt, Date(timeIntervalSince1970: 2_600))
    }

    func testPendingRecoveryNotificationsSkipDisabledProvider() async throws {
        let store = try makeStore()
        let edge = recoveryEdge()
        try store.recordRecoveryEdge(edge)
        try store.setRecoveryReminderPreference(tool: .codex, windowKind: .weekly, isEnabled: true, updatedAt: Date())
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client, providerEnabled: { $0 != .codex })

        await service.sendPendingNotifications(from: store)

        XCTAssertEqual(client.sentTitles, [])
        XCTAssertNil(try store.recoveryEdgeRecords().first?.firedAt)
    }

    func testStaleIntervalDropsWithoutDelivery() async throws {
        let store = try makeStore()
        try store.recordAcceptedSnapshot(usageSnapshot(weeklyReset: Date(timeIntervalSince1970: 4_000)), acceptedAt: Date(timeIntervalSince1970: 3_000))
        try store.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 5,
            resetIntervalID: "weekly:10080:2000",
            detectedAt: Date(timeIntervalSince1970: 3_100)
        )
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client)

        await service.sendPendingThresholdNotifications(from: store)

        XCTAssertEqual(client.sentIdentifiers, [])
        XCTAssertTrue(try store.pendingThresholdNotificationRecords().isEmpty)
    }

    func testDrainRespectsDisabledThresholdPreference() async throws {
        let store = try makeStore()
        let reset = Date(timeIntervalSince1970: 2_000)
        let resetID = UsageRecoveryPolicy.resetIntervalID(for: weekly(reset: reset))
        try store.recordAcceptedSnapshot(usageSnapshot(weeklyReset: reset), acceptedAt: Date(timeIntervalSince1970: 1_900))
        try store.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 20,
            resetIntervalID: resetID,
            detectedAt: Date(timeIntervalSince1970: 1_950)
        )
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client)

        await service.sendPendingThresholdNotifications(from: store)

        XCTAssertEqual(client.sentIdentifiers, [])
        XCTAssertEqual(try store.pendingThresholdNotificationRecords().first?.lastError, "preference_disabled")
    }

    func testDrainMarksThresholdDisabledWhenProviderDisabled() async throws {
        let store = try makeStore()
        let reset = Date(timeIntervalSince1970: 2_000)
        let resetID = UsageRecoveryPolicy.resetIntervalID(for: weekly(reset: reset))
        try store.recordAcceptedSnapshot(usageSnapshot(weeklyReset: reset), acceptedAt: Date(timeIntervalSince1970: 1_900))
        try store.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 20,
            resetIntervalID: resetID,
            detectedAt: Date(timeIntervalSince1970: 1_950)
        )
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client, providerEnabled: { $0 != .codex })

        await service.sendPendingThresholdNotifications(from: store)

        XCTAssertEqual(client.sentIdentifiers, [])
        XCTAssertEqual(try store.pendingThresholdNotificationRecords().first?.lastError, "provider_disabled")
    }

    func testDrainDeliversThresholdWhenAllConditionsMet() async throws {
        let store = try makeStore()
        let reset = Date(timeIntervalSince1970: 2_000)
        let resetID = UsageRecoveryPolicy.resetIntervalID(for: weekly(reset: reset))
        try store.recordAcceptedSnapshot(usageSnapshot(weeklyReset: reset), acceptedAt: Date(timeIntervalSince1970: 1_900))
        try store.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 20,
            resetIntervalID: resetID,
            detectedAt: Date(timeIntervalSince1970: 1_950)
        )
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client, now: { Date(timeIntervalSince1970: 2_700) })

        await service.sendPendingThresholdNotifications(from: store)

        XCTAssertEqual(client.sentIdentifiers, ["bough.usage-threshold.codex.weekly.20.\(resetID)"])
        XCTAssertEqual(client.sentTitles, ["Codex weekly quota at 20% remaining"])
        XCTAssertTrue(try store.pendingThresholdNotificationRecords().isEmpty)
    }

    func testRecoveryDrainCompletesBeforeThresholdDrain() async throws {
        let store = try makeStore()
        let reset = Date(timeIntervalSince1970: 2_000)
        let resetID = UsageRecoveryPolicy.resetIntervalID(for: weekly(reset: reset))
        let edge = recoveryEdge(resetIntervalID: resetID)
        try store.recordAcceptedSnapshot(usageSnapshot(weeklyReset: reset), acceptedAt: Date(timeIntervalSince1970: 1_900))
        try store.recordRecoveryEdge(edge)
        try store.setRecoveryReminderPreference(tool: .codex, windowKind: .weekly, isEnabled: true, updatedAt: Date())
        try store.setThresholdNotificationsMasterEnabled(isEnabled: true, updatedAt: Date())
        try store.recordThresholdCrossing(
            tool: .codex,
            windowKind: .weekly,
            thresholdPct: 20,
            resetIntervalID: resetID,
            detectedAt: Date(timeIntervalSince1970: 1_950)
        )
        try store.setThresholdNotificationPreference(tool: .codex, isEnabled: true, updatedAt: Date())
        let client = FakeUsageNotificationClient(status: .authorized)
        let service = UsageNotificationService(client: client)

        await service.sendPendingNotifications(from: store)
        await service.sendPendingThresholdNotifications(from: store)

        XCTAssertEqual(client.sentIdentifiers.count, 2)
        XCTAssertTrue(client.sentIdentifiers[0].hasPrefix("bough.usage-recovery."))
        XCTAssertTrue(client.sentIdentifiers[1].hasPrefix("bough.usage-threshold."))
    }

    func testInfoPlistDoesNotRequestRemindersAccess() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Platform/Apple/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertNil(plist["NSRemindersFullAccessUsageDescription"])
    }

    private func makeStore() throws -> UsageContinuityStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageNotificationServiceTests-\(UUID().uuidString).sqlite")
            .path
        return try UsageContinuityStore(path: path)
    }

    private func recoveryEdge(resetIntervalID: String = "weekly:10080:2000") -> UsageRecoveryEdge {
        UsageRecoveryEdge(
            tool: .codex,
            windowKind: .weekly,
            resetIntervalID: resetIntervalID,
            acceptedSequence: 2,
            priorUsedPercent: 100,
            currentUsedPercent: 20,
            resetProvenance: .explicitReset,
            detectedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    private func usageSnapshot(weeklyReset: Date, weeklyUsed: Double = 81) -> UsageSnapshot {
        UsageSnapshot(
            tool: .codex,
            planName: "prolite",
            fiveHour: .available(UsageWindowSnapshot(
                kind: .fiveHour,
                usedPercent: 12,
                resetsAt: Date(timeIntervalSince1970: 2_100),
                windowDurationMins: 300,
                sourceLabel: "test",
                updatedAt: Date(timeIntervalSince1970: 1_900)
            )),
            weekly: .available(weekly(reset: weeklyReset, used: weeklyUsed)),
            today: nil,
            availability: .available,
            lastRefresh: Date(timeIntervalSince1970: 1_900)
        )
    }

    private func weekly(reset: Date, used: Double = 81) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: .weekly,
            usedPercent: used,
            resetsAt: reset,
            windowDurationMins: 10_080,
            sourceLabel: "test",
            updatedAt: Date(timeIntervalSince1970: 1_900)
        )
    }
}

private final class FakeUsageNotificationClient: UsageNotificationCenterClient, @unchecked Sendable {
    var status: UsageNotificationPermissionState
    var requestedStatus: UsageNotificationPermissionState
    var sendError: Error?
    private(set) var requestCount = 0
    private(set) var sentIdentifiers: [String] = []
    private(set) var sentTitles: [String] = []

    init(
        status: UsageNotificationPermissionState,
        requestedStatus: UsageNotificationPermissionState? = nil,
        sendError: Error? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
        self.sendError = sendError
    }

    func permissionState() async -> UsageNotificationPermissionState {
        status
    }

    func requestAuthorization() async -> UsageNotificationPermissionState {
        requestCount += 1
        status = requestedStatus
        return requestedStatus
    }

    func sendNotification(identifier: String, title: String, body: String) async throws {
        if let sendError { throw sendError }
        sentIdentifiers.append(identifier)
        sentTitles.append(title)
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "failed"
    }
}
