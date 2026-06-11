import XCTest
import Observation
@testable import Bough
@testable import BoughCore

@MainActor
final class UsageStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "UsageStoreTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSelectedProviderPersistsAndRestoresSupportedProvider() {
        var now = Date(timeIntervalSince1970: 100)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { now })
        store.selectedTool = .codex
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageSelectedProvider), "codex")

        now = Date(timeIntervalSince1970: 101)
        let restored = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { now })
        XCTAssertEqual(restored.selectedTool, .codex)
    }

    func testPersistedClaudeSelectionRestoresAsUnavailableProvider() {
        defaults.set("claudeCode", forKey: SettingsKey.usageSelectedProvider)

        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        XCTAssertEqual(store.selectedTool, .claudeCode)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageSelectedProvider), "claudeCode")
        XCTAssertEqual(store.snapshot(for: .claudeCode).availability, .unavailable(reason: "No reliable local quota source"))
    }

    func testSelectableToolsIncludesClaudeCodeWithUnavailableSnapshot() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        XCTAssertEqual(store.selectableTools, [.codex, .claudeCode])
    }

    func testUsageDisplayToggleRemovesProviderFromSelectableTools() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        store.setUsageDisplayEnabled(tool: .claudeCode, isEnabled: false)

        XCTAssertEqual(store.displayableTools, [.codex])
        XCTAssertEqual(store.selectableTools, [.codex])
    }

    func testDisablingSelectedDisplayProviderMovesSelectionToRemainingProvider() {
        defaults.set("claudeCode", forKey: SettingsKey.usageSelectedProvider)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        store.setUsageDisplayEnabled(tool: .claudeCode, isEnabled: false)

        XCTAssertEqual(store.selectedTool, .codex)
        XCTAssertEqual(store.selectedDisplayTool, .codex)
    }

    func testPersistedHiddenSelectedDisplayProviderRestoresToVisibleProvider() {
        defaults.set("claudeCode", forKey: SettingsKey.usageSelectedProvider)
        defaults.set(false, forKey: SettingsKey.usageDisplayEnabled("claudeCode"))

        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        XCTAssertEqual(store.selectedTool, .codex)
        XCTAssertEqual(store.selectedDisplayTool, .codex)
    }

    func testAllDisplayProvidersCanBeHidden() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        store.setUsageDisplayEnabled(tool: .codex, isEnabled: false)
        store.setUsageDisplayEnabled(tool: .claudeCode, isEnabled: false)

        XCTAssertEqual(store.displayableTools, [])
        XCTAssertEqual(store.selectableTools, [])
        XCTAssertNil(store.selectedDisplayTool)
    }

    func testEnablingOnlyDisplayProviderMovesSelectionToEnabledProvider() {
        defaults.set(false, forKey: SettingsKey.usageDisplayEnabled("codex"))
        defaults.set(false, forKey: SettingsKey.usageDisplayEnabled("claudeCode"))
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })

        store.setUsageDisplayEnabled(tool: .claudeCode, isEnabled: true)

        XCTAssertEqual(store.selectedTool, .claudeCode)
        XCTAssertEqual(store.selectedDisplayTool, .claudeCode)
    }

    func testClaudeSnapshotIsUnavailable() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 100) })
        XCTAssertEqual(store.snapshot(for: .claudeCode).availability, .unavailable(reason: "No reliable local quota source"))
    }

    func testManualRefreshAppliesResultAndBuildsForecast() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000))
        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)

        await store.refreshCodexOAuth(force: true)

        XCTAssertGreaterThanOrEqual(fetcher.fetchCount, 1)
        XCTAssertEqual(store.snapshot(for: .codex).weekly.snapshot?.usedPercent, 20)
        XCTAssertNotNil(store.snapshot(for: .codex).today)
        XCTAssertEqual(store.codexOAuthStatus, .connected(at: Date(timeIntervalSince1970: 1_000)))
    }

    func testSnapshotAvailabilityChangeIsObservable() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let observed = expectation(description: "snapshot update observed")
        withObservationTracking({
            _ = store.snapshot(for: .codex).availability
        }, onChange: {
            observed.fulfill()
        })

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000))
        await Task.yield()
        await fulfillment(of: [observed], timeout: 1)
    }

    func testTimerRefreshUsesActiveTwoMinutesAndCanBeFiredInTests() async {
        let scheduler = RecordingUsageRefreshScheduler()
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000))
        let store = UsageStore(defaults: defaults, scheduler: scheduler, now: { Date(timeIntervalSince1970: 1_000) })

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        XCTAssertEqual(scheduler.interval, 120)
        await waitUntil { fetcher.fetchCount >= 1 && !store.isRefreshing }
        let readsAfterInitialRefresh = fetcher.fetchCount
        scheduler.fire()
        await waitUntil { fetcher.fetchCount > readsAfterInitialRefresh }
    }

    func testIdleRefreshUsesFiveMinutes() {
        let scheduler = RecordingUsageRefreshScheduler()
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000))
        let store = UsageStore(defaults: defaults, scheduler: scheduler, now: { Date(timeIntervalSince1970: 1_000) })

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        store.setRefreshActivity(.idle)

        XCTAssertEqual(scheduler.interval, 300)
    }

    func testStaleAfterFifteenMinutes() {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { current })
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000))

        current = Date(timeIntervalSince1970: 1_901)
        store.evaluateStaleness()

        let snapshot = store.snapshot(for: .codex)
        XCTAssertEqual(snapshot.availability, .stale(reason: "Usage data is stale"))
        XCTAssertEqual(snapshot.weekly.staleReason, "Usage data is stale")
    }

    func testRequestFailureRetainsLastGoodAsStale() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000))
        store.startUsageChannels(claude: nil, codex: FakeCodexUsageFetcher(error: UsageStoreTestError.failed), codexFallback: nil)

        await store.refreshCodexOAuth()

        let snapshot = store.snapshot(for: .codex)
        XCTAssertEqual(snapshot.availability, .stale(reason: L10n.shared["usage_refresh_failed"]))
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 20)
        XCTAssertNil(snapshot.today)
    }

    func testMalformedRefreshPreservesLastGoodSnapshot() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000))
        store.startUsageChannels(claude: nil, codex: FakeCodexUsageFetcher(result: ["rateLimitsByLimitId": .object([:])]), codexFallback: nil)

        await store.refreshCodexOAuth()

        XCTAssertEqual(store.snapshot(for: .codex).weekly.snapshot?.usedPercent, 20)
    }

    func testInitialMalformedRefreshMarksCodexUnavailable() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        store.startUsageChannels(claude: nil, codex: FakeCodexUsageFetcher(result: ["rateLimitsByLimitId": .object([:])]), codexFallback: nil)

        await store.refreshCodexOAuth()

        XCTAssertEqual(store.snapshot(for: .codex).availability, .unavailable(reason: L10n.shared["usage_refresh_failed"]))
    }

    func testPastWeeklyResetSampleIsStaleUntilNextRefreshRestoresForecast() async {
        let scheduler = RecordingUsageRefreshScheduler()
        let store = UsageStore(defaults: defaults, scheduler: scheduler, now: { Date(timeIntervalSince1970: 2_000) })
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000, fiveHourUsedPercent: 30, weeklyUsedPercent: 40))
        fetcher.enqueue(.success(Self.codexResult(weeklyReset: 1_999, fiveHourUsedPercent: 10, weeklyUsedPercent: 20)))

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        await waitUntil { fetcher.fetchCount >= 1 && !store.isRefreshing }

        let snapshot = store.snapshot(for: .codex)
        XCTAssertNil(snapshot.today)
        XCTAssertEqual(snapshot.availability, .stale(reason: "Usage data is stale"))
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 10)

        await store.refreshCodexOAuth()

        let refreshed = store.snapshot(for: .codex)
        XCTAssertEqual(refreshed.availability, .available)
        XCTAssertEqual(refreshed.fiveHour.snapshot?.usedPercent, 30)
        XCTAssertEqual(refreshed.weekly.snapshot?.usedPercent, 40)
        XCTAssertNotNil(refreshed.today)
    }

    func testCodexAcceptedSamplesCarryForwardExplicitReset() throws {
        // Isolate ~/.bough/usage-daily.json: the live accumulator persists the
        // re-lock idempotency marker (spec §8.1), so a leaked baseline from a
        // previous run would suppress the re-lock this test asserts.
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
            try? FileManager.default.removeItem(at: tempHome)
        }

        var current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { current })

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 1_500, weeklyUsedPercent: 80))
        current = Date(timeIntervalSince1970: 1_600)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 5))

        let today = store.snapshot(for: .codex).today
        XCTAssertEqual(today?.basis.resetProvenance, .explicitReset)
        XCTAssertEqual(today?.basis.weeklyResetAlreadyFiredToday, true)
        let basis = try XCTUnwrap(today?.basis)
        // Spec §8.1: the accumulator re-locks the baseline at the explicit reset,
        // so the basis starts at the post-reset usedPercent and Today is full —
        // no pre-reset segment carry-forward into today_used.
        XCTAssertEqual(basis.weeklyUsedAtDayStart, 5, accuracy: 0.001)
        let todayUsed = max(0, basis.weeklyUsedNow - basis.weeklyUsedAtDayStart)
        let expectedPct = ((basis.todayAllowanceOfWeek - todayUsed) / basis.todayAllowanceOfWeek) * 100.0
        XCTAssertEqual(today?.pct ?? 999, expectedPct, accuracy: 0.001)
        XCTAssertEqual(today?.pct ?? 999, 100.0, accuracy: 0.001)
    }

    func testCodexAcceptedSamplesCarryForwardImplicitReset() throws {
        // Isolate ~/.bough/usage-daily.json (see explicit-reset test above).
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
            try? FileManager.default.removeItem(at: tempHome)
        }

        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 82))
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 200_000, weeklyUsedPercent: 4))

        let today = store.snapshot(for: .codex).today
        XCTAssertEqual(today?.basis.resetProvenance, .implicitReset)
        XCTAssertEqual(today?.basis.weeklyResetAlreadyFiredToday, true)
        // Spec §8.1: the implicit reset re-locks the baseline at the post-reset
        // usedPercent (4), so Today starts the new week at full allowance.
        XCTAssertEqual(today?.basis.weeklyUsedAtDayStart ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(today?.pct ?? 999, 100.0, accuracy: 0.001)
    }

    func testFailedRefreshPreservedStaleSampleDoesNotTriggerResetCarryForward() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(error: UsageStoreTestError.failed)

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 80))
        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        await waitUntil { fetcher.fetchCount >= 1 && !store.isRefreshing }
        await store.refreshCodexOAuth()
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 200_000, weeklyUsedPercent: 4))

        let today = store.snapshot(for: .codex).today
        XCTAssertEqual(today?.basis.resetProvenance, .ordinaryProgress)
        XCTAssertEqual(today?.basis.weeklyResetAlreadyFiredToday, false)
        XCTAssertEqual(today?.pct ?? -1, 100.0, accuracy: 0.001)
    }

    func testContinuityWriterModeFollowsDefaultsAfterHelperToggle() throws {
        let path = Self.temporaryContinuityPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let continuityStore = try UsageContinuityStore(path: path.path)
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            now: { current },
            continuityStore: continuityStore
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))
        XCTAssertEqual(try continuityStore.acceptedSampleCount(tool: .codex), 1)

        defaults.set(UsageContinuityWriterOwner.helper.rawValue, forKey: SettingsKey.usageContinuityWriterOwner)
        current = Date(timeIntervalSince1970: 1_100)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 21))

        XCTAssertEqual(try continuityStore.acceptedSampleCount(tool: .codex), 1)
    }

    func testContinuityWriterModeOverrideRemainsFixedForInjectedHelperMode() throws {
        let path = Self.temporaryContinuityPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let continuityStore = try UsageContinuityStore(path: path.path)
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            now: { current },
            continuityStore: continuityStore,
            continuityWriteMode: .helperOwned
        )

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))
        defaults.set(UsageContinuityWriterOwner.app.rawValue, forKey: SettingsKey.usageContinuityWriterOwner)
        current = Date(timeIntervalSince1970: 1_100)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 21))

        XCTAssertEqual(try continuityStore.acceptedSampleCount(tool: .codex), 0)
    }

    func testStatisticsDisabledPreventsAppContinuityWrites() throws {
        let path = Self.temporaryContinuityPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let continuityStore = try UsageContinuityStore(path: path.path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            now: { Date(timeIntervalSince1970: 1_000) },
            continuityStore: continuityStore
        )

        store.setUsageStatisticsEnabled(tool: .codex, isEnabled: false)
        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20))

        XCTAssertEqual(try continuityStore.acceptedSampleCount(tool: .codex), 0)
        XCTAssertEqual(store.snapshot(for: .codex).weekly.snapshot?.usedPercent, 20)
    }

    func testStatisticsToggleWritesHelperCommandFile() throws {
        let commandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage-monitor-command.json")
        defer { try? FileManager.default.removeItem(at: commandURL.deletingLastPathComponent()) }
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            usageMonitorCommandPath: commandURL.path,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        store.setUsageStatisticsEnabled(tool: .claudeCode, isEnabled: false)

        let data = try Data(contentsOf: commandURL)
        let command = try JSONDecoder().decode(UsageMonitorCommand.self, from: data)
        XCTAssertEqual(command.enabledTools, [.codex])
    }

    func testStatisticsToggleProtectsBoughHelperCommandFilePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
        let boughDir = root.appendingPathComponent(".bough", isDirectory: true)
        let commandURL = boughDir.appendingPathComponent("usage-monitor-command.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            usageMonitorCommandPath: commandURL.path,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        store.setUsageStatisticsEnabled(tool: .claudeCode, isEnabled: false)

        XCTAssertEqual(try posixPermissions(of: boughDir), 0o700)
        XCTAssertEqual(try posixPermissions(of: commandURL), 0o600)
    }

    func testDisabledCodingSessionsPauseStopsRefreshAndPreservesPreferences() async throws {
        let commandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage-monitor-command.json")
        defer { try? FileManager.default.removeItem(at: commandURL.deletingLastPathComponent()) }
        let scheduler = RecordingUsageRefreshScheduler()
        defaults.set("claudeCode", forKey: SettingsKey.usageSelectedProvider)
        defaults.set(false, forKey: SettingsKey.usageStatisticsEnabled("claudeCode"))
        let store = UsageStore(
            defaults: defaults,
            scheduler: scheduler,
            usageMonitorCommandPath: commandURL.path,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000))

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        await waitUntil { fetcher.fetchCount >= 1 && !store.isRefreshing }
        store.applyClaudeCodePayload(Self.claudePayload(weeklyUsedPercent: 12, weeklyReset: 100_000), receivedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(store.snapshots[.codex])
        XCTAssertNotNil(store.snapshots[.claudeCode])

        store.pauseCodingSessionCollectionForDisabledMode()
        let readsAfterPause = fetcher.fetchCount
        scheduler.fire()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fetcher.fetchCount, readsAfterPause)
        XCTAssertNil(store.snapshots[.codex])
        XCTAssertNil(store.snapshots[.claudeCode])
        XCTAssertEqual(defaults.string(forKey: SettingsKey.usageSelectedProvider), "claudeCode")
        XCTAssertEqual(defaults.object(forKey: SettingsKey.usageStatisticsEnabled("claudeCode")) as? Bool, false)

        var command = try JSONDecoder().decode(UsageMonitorCommand.self, from: Data(contentsOf: commandURL))
        XCTAssertEqual(command.enabledTools, [])

        store.resumeCodingSessionCollectionForEnabledMode()
        command = try JSONDecoder().decode(UsageMonitorCommand.self, from: Data(contentsOf: commandURL))
        XCTAssertEqual(command.enabledTools, [.codex])
    }

    func testDisabledCodingSessionsInitDoesNotSeedUsageSnapshots() throws {
        let commandURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage-monitor-command.json")
        defer { try? FileManager.default.removeItem(at: commandURL.deletingLastPathComponent()) }

        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            usageMonitorCommandPath: commandURL.path,
            now: { Date(timeIntervalSince1970: 1_000) },
            codingSessionsEnabled: false
        )

        XCTAssertNil(store.snapshots[.codex])
        XCTAssertNil(store.snapshots[.claudeCode])
        let command = try JSONDecoder().decode(UsageMonitorCommand.self, from: Data(contentsOf: commandURL))
        XCTAssertEqual(command.enabledTools, [])
    }

    func testThresholdNotificationsMasterEnabledWrapsSQLiteMasterPreference() throws {
        let path = Self.temporaryContinuityPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let continuityStore = try UsageContinuityStore(path: path.path)
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            now: { Date(timeIntervalSince1970: 1_000) },
            continuityStore: continuityStore
        )

        XCTAssertFalse(store.thresholdNotificationsMasterEnabled())

        try continuityStore.setThresholdNotificationsMasterEnabled(
            isEnabled: true,
            updatedAt: Date(timeIntervalSince1970: 1_100)
        )
        XCTAssertTrue(store.thresholdNotificationsMasterEnabled())

        try continuityStore.setThresholdNotificationsMasterEnabled(
            isEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 1_200)
        )
        XCTAssertFalse(store.thresholdNotificationsMasterEnabled())
    }

    func testCodexPriorSampleDoesNotAffectClaudeCodeResetProvenance() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 90))
        store.applyClaudeCodePayload(Self.claudePayload(weeklyUsedPercent: 4, weeklyReset: 200_000), receivedAt: Date(timeIntervalSince1970: 1_000))

        let today = store.snapshot(for: .claudeCode).today
        XCTAssertEqual(today?.basis.resetProvenance, .ordinaryProgress)
        XCTAssertEqual(today?.basis.weeklyResetAlreadyFiredToday, false)
    }

    func testInFlightRefreshDoesNotApplyAfterStopUsageChannels() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000))
        let started = expectation(description: "fetch started")
        started.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        fetcher.onFetchStart = { started.fulfill() }
        fetcher.blockGate = gate

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        await fulfillment(of: [started], timeout: 2)
        store.stopUsageChannels()
        gate.signal()
        await waitUntil { !store.isRefreshing }

        // Generation bumped by stop — the stale in-flight result must not land.
        XCTAssertEqual(store.snapshot(for: .codex).availability, .loading)
        XCTAssertNil(store.snapshot(for: .codex).weekly.snapshot)
    }

    // MARK: - Claude OAuth channel (spec §9)

    func testClaudeOAuthRefreshAppliesSnapshotSetsConnectedAndWritesMirror() async throws {
        let paths = Self.temporaryClaudePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let payload = Self.claudePayload()
        let fetcher = FakeClaudeUsageFetcher(result: .success(payload))
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            claudeUsageFilePath: paths.usage.path,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        store.startUsageChannels(claude: fetcher, codex: nil, codexFallback: nil)
        await store.refreshClaudeOAuth()

        let snapshot = store.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 12)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 24)
        XCTAssertNotNil(snapshot.today)
        XCTAssertEqual(store.claudeOAuthStatus, .connected(at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(try Data(contentsOf: paths.usage), payload)
    }

    func testClaudeOAuthFailureSetsDegradedStatusAndUnavailableSnapshot() async {
        let fetcher = FakeClaudeUsageFetcher(result: .failure(OAuthUsageError.tokenExpired))
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        store.startUsageChannels(claude: fetcher, codex: nil, codexFallback: nil)
        await store.refreshClaudeOAuth()

        let reason = L10n.shared["usage_oauth_token_expired"]
        XCTAssertEqual(store.claudeOAuthStatus, .degraded(reason: reason, at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(store.snapshot(for: .claudeCode).availability, .unavailable(reason: reason))
    }

    func testClaudeOAuthNoCredentialsSetsMissingCredentialsStatus() async {
        // Spec §9: no credentials is its own (gray) status, not degraded.
        let fetcher = FakeClaudeUsageFetcher(
            result: .failure(OAuthUsageError.credentialsUnavailable(reason: "no sources")))
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        store.startUsageChannels(claude: fetcher, codex: nil, codexFallback: nil)
        await store.refreshClaudeOAuth()

        let reason = L10n.shared["usage_oauth_no_credentials"]
        XCTAssertEqual(store.claudeOAuthStatus, .missingCredentials(reason: reason, at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(store.snapshot(for: .claudeCode).availability, .unavailable(reason: reason))
    }

    func testForceClaudeRefreshResetsTransientGates() async {
        let fetcher = FakeClaudeUsageFetcher(result: .success(Self.claudePayload()))
        let paths = Self.temporaryClaudePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = UsageStore(
            defaults: defaults,
            scheduler: RecordingUsageRefreshScheduler(),
            claudeUsageFilePath: paths.usage.path,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        store.startUsageChannels(claude: fetcher, codex: nil, codexFallback: nil)
        await store.refreshClaudeOAuth(force: true)

        XCTAssertEqual(fetcher.resetCount, 1)
    }

    // MARK: - Codex OAuth channel + auth-failure fallback (spec §5.3)

    func testCodexAuthFailureFallsBackToAppServerReader() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(error: OAuthUsageError.unauthorized(statusCode: 401))
        let fallback = FakeCodexFallbackReader(result: Self.codexResult(weeklyReset: 100_000))

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: fallback)
        await store.refreshCodexOAuth()

        XCTAssertGreaterThanOrEqual(fallback.readCount, 1)
        XCTAssertEqual(store.snapshot(for: .codex).weekly.snapshot?.usedPercent, 20)
        XCTAssertEqual(store.codexOAuthStatus, .connected(at: Date(timeIntervalSince1970: 1_000)))
    }

    func testCodexNetworkFailureDoesNotFallBack() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(error: OAuthUsageError.network("offline"))
        let fallback = FakeCodexFallbackReader(result: Self.codexResult(weeklyReset: 100_000))

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: fallback)
        await store.refreshCodexOAuth()
        await waitUntil { fetcher.fetchCount >= 1 && !store.isRefreshing }

        XCTAssertEqual(fallback.readCount, 0)
        let reason = L10n.shared["usage_refresh_failed"]
        XCTAssertEqual(store.codexOAuthStatus, .degraded(reason: reason, at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(store.snapshot(for: .codex).availability, .unavailable(reason: reason))
    }

    func testCodexFallbackFailureSurfacesOriginalOAuthReason() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(error: OAuthUsageError.tokenExpired)
        let fallback = FakeCodexFallbackReader(error: UsageStoreTestError.failed)

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: fallback)
        await store.refreshCodexOAuth()

        XCTAssertGreaterThanOrEqual(fallback.readCount, 1)
        let reason = L10n.shared["usage_oauth_token_expired"]
        XCTAssertEqual(store.codexOAuthStatus, .degraded(reason: reason, at: Date(timeIntervalSince1970: 1_000)))
    }

    func testCodexNoCredentialsSetsMissingCredentialsStatus() async {
        // Spec §9: no credentials is its own (gray) status, not degraded.
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })
        let fetcher = FakeCodexUsageFetcher(error: OAuthUsageError.credentialsUnavailable(reason: "no auth.json"))

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        await store.refreshCodexOAuth()

        let reason = L10n.shared["usage_oauth_no_credentials"]
        XCTAssertEqual(store.codexOAuthStatus, .missingCredentials(reason: reason, at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(store.snapshot(for: .codex).availability, .unavailable(reason: reason))
    }

    // MARK: - Sample arbitration (spec §9)

    func testOlderClaudeSampleDoesNotClobberNewerSnapshot() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertTrue(store.applyClaudeCodePayload(Self.claudePayload(fiveHourUsedPercent: 12), receivedAt: Date(timeIntervalSince1970: 1_000)))
        XCTAssertFalse(store.applyClaudeCodePayload(Self.claudePayload(fiveHourUsedPercent: 99), receivedAt: Date(timeIntervalSince1970: 900)))

        XCTAssertEqual(store.snapshot(for: .claudeCode).fiveHour.snapshot?.usedPercent, 12)
        XCTAssertEqual(store.snapshot(for: .claudeCode).lastRefresh, Date(timeIntervalSince1970: 1_000))
    }

    func testOlderCodexSampleDoesNotClobberNewerSnapshot() {
        var current = Date(timeIntervalSince1970: 2_000)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { current })

        XCTAssertTrue(store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 20)))
        current = Date(timeIntervalSince1970: 1_500)
        XCTAssertFalse(store.applyCodexRateLimitResult(Self.codexResult(weeklyReset: 100_000, weeklyUsedPercent: 99)))

        XCTAssertEqual(store.snapshot(for: .codex).weekly.snapshot?.usedPercent, 20)
        XCTAssertEqual(store.snapshot(for: .codex).lastRefresh, Date(timeIntervalSince1970: 2_000))
    }

    // MARK: - Panel-open refresh

    func testPanelOpenRefreshDeduplicatesWithinMinInterval() async {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { current })
        let fetcher = FakeCodexUsageFetcher(result: Self.codexResult(weeklyReset: 100_000))

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)
        await waitUntil { fetcher.fetchCount >= 1 && !store.isRefreshing }
        let baseline = fetcher.fetchCount

        store.refreshForPanelOpenIfNeeded()
        await waitUntil { fetcher.fetchCount == baseline + 1 && !store.isRefreshing }

        store.refreshForPanelOpenIfNeeded()  // within 30s — must be a no-op
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcher.fetchCount, baseline + 1)

        current = current.addingTimeInterval(31)
        store.refreshForPanelOpenIfNeeded()
        await waitUntil { fetcher.fetchCount == baseline + 2 }
    }

    // MARK: - degradedReason mapping (pure)

    func testDegradedReasonMapsOAuthErrors() {
        let localized: (String) -> String = { $0 }

        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.credentialsUnavailable(reason: "x"), localized: localized),
            "usage_oauth_no_credentials"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.tokenExpired, localized: localized),
            "usage_oauth_token_expired"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.keychainDenied, localized: localized),
            "usage_oauth_keychain_denied"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.rateLimited(retryAfterSeconds: nil), localized: localized),
            "usage_oauth_rate_limited"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.cooldownActive(until: .distantFuture), localized: localized),
            "usage_oauth_rate_limited"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.unauthorized(statusCode: 401), localized: localized),
            "usage_oauth_unauthorized"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.httpStatus(500), localized: localized),
            "usage_refresh_failed"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.network("offline"), localized: localized),
            "usage_refresh_failed"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: OAuthUsageError.parseFailed, localized: localized),
            "usage_refresh_failed"
        )
        XCTAssertEqual(
            UsageStore.degradedReason(for: UsageStoreTestError.failed, localized: localized),
            "usage_refresh_failed"
        )
    }

    // MARK: - Claude payload application

    func testApplyClaudeCodePayloadBuildsSnapshotAndForecast() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertTrue(store.applyClaudeCodePayload(Self.claudePayload(), receivedAt: Date(timeIntervalSince1970: 1_000)))

        let snapshot = store.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.planName, "Claude Sonnet 4")
        XCTAssertEqual(snapshot.fiveHour.snapshot?.usedPercent, 12)
        XCTAssertEqual(snapshot.weekly.snapshot?.usedPercent, 24)
        XCTAssertNotNil(snapshot.today)
    }

    func testClaudePayloadMissingRateLimitsMarksUnavailable() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertFalse(store.applyClaudeCodePayload(Data(#"{"model":"Claude"}"#.utf8), receivedAt: Date(timeIntervalSince1970: 1_000)))

        XCTAssertEqual(
            store.snapshot(for: .claudeCode).availability,
            .unavailable(reason: L10n.shared["usage_claude_payload-missing-rate-limits"])
        )
    }

    func testClaudeMalformedPayloadMarksParseFailure() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertFalse(store.applyClaudeCodePayload(Data(#"{"rate_limits":"#.utf8), receivedAt: Date(timeIntervalSince1970: 1_000)))

        XCTAssertEqual(
            store.snapshot(for: .claudeCode).availability,
            .unavailable(reason: L10n.shared["usage_claude_parse-failure"])
        )
    }

    func testApplyClaudeCodePayloadWithOldTimestampMarksStaleImmediately() {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { Date(timeIntervalSince1970: 2_000) })

        XCTAssertTrue(store.applyClaudeCodePayload(Self.claudePayload(), receivedAt: Date(timeIntervalSince1970: 100)))

        let snapshot = store.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .stale(reason: "Usage data is stale"))
        XCTAssertEqual(snapshot.fiveHour.staleReason, "Usage data is stale")
        XCTAssertEqual(snapshot.weekly.staleReason, "Usage data is stale")
        XCTAssertNil(snapshot.today)
    }

    func testClaudeSnapshotStalesAfterFifteenMinutes() {
        var current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { current })
        store.applyClaudeCodePayload(Self.claudePayload(), receivedAt: current)

        current = Date(timeIntervalSince1970: 1_901)
        store.evaluateStaleness()

        let snapshot = store.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .stale(reason: L10n.shared["usage_claude_stale"]))
        XCTAssertEqual(snapshot.weekly.staleReason, L10n.shared["usage_claude_stale"])
        XCTAssertNil(snapshot.today)
    }

    func testFutureClaudeSnapshotStalesImmediately() {
        let current = Date(timeIntervalSince1970: 1_000)
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler(), now: { current })
        store.applyClaudeCodePayload(Self.claudePayload(), receivedAt: current.addingTimeInterval(120))

        store.evaluateStaleness()

        let snapshot = store.snapshot(for: .claudeCode)
        XCTAssertEqual(snapshot.availability, .stale(reason: L10n.shared["usage_claude_stale"]))
        XCTAssertEqual(snapshot.weekly.staleReason, L10n.shared["usage_claude_stale"])
        XCTAssertNil(snapshot.today)
    }

    static func codexResult(
        weeklyReset: Int64,
        fiveHourUsedPercent: Int64 = 10,
        weeklyUsedPercent: Int64 = 20
    ) -> [String: AnyCodableLike] {
        [
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "limitId": .string("codex"),
                    "primary": .object(["usedPercent": .int(fiveHourUsedPercent), "windowDurationMins": .int(300), "resetsAt": .int(2_000)]),
                    "secondary": .object(["usedPercent": .int(weeklyUsedPercent), "windowDurationMins": .int(10_080), "resetsAt": .int(weeklyReset)]),
                    "planType": .string("prolite")
                ])
            ])
        ]
    }

    private static func claudePayload(
        fiveHourUsedPercent: Int = 12,
        weeklyUsedPercent: Int = 24,
        weeklyReset: Int64 = 100_000
    ) -> Data {
        Data(
            """
            {
              "version": 1,
              "model": {"display_name": "Claude Sonnet 4"},
              "rate_limits": {
                "five_hour": {
                  "used_percent": \(fiveHourUsedPercent),
                  "resets_at": 2000,
                  "window_duration_mins": 300
                },
                "seven_day": {
                  "used_percent": \(weeklyUsedPercent),
                  "resets_at": \(weeklyReset),
                  "window_duration_mins": 10080
                }
              }
            }
            """.utf8
        )
    }

    private static func temporaryClaudePaths() -> (root: URL, usage: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)")
        return (
            root,
            root.appendingPathComponent(".bough/claude-usage.json")
        )
    }

    private static func temporaryContinuityPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage-continuity.sqlite")
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

}

private enum UsageStoreTestError: Error { case failed }

/// Polls a main-actor condition until it holds or the timeout elapses.
/// The OAuth fetchers run on detached tasks, so count-based assertions need
/// a brief quiescence window instead of bare `Task.yield()` loops.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(condition(), "condition not met within \(timeout)s")
}

/// Thread-safe ClaudeUsageFetching fake — `fetchStatusLinePayload` runs on a
/// detached task off the main actor, so all state is lock-protected.
private final class FakeClaudeUsageFetcher: ClaudeUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Data, Error>
    private var fetchCountStorage = 0
    private var resetCountStorage = 0

    init(result: Result<Data, Error>) {
        self.result = result
    }

    var fetchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchCountStorage
    }

    var resetCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resetCountStorage
    }

    func fetchStatusLinePayload() throws -> Data {
        lock.lock()
        fetchCountStorage += 1
        lock.unlock()
        return try result.get()
    }

    func resetTransientGates() {
        lock.lock()
        resetCountStorage += 1
        lock.unlock()
    }
}

/// Thread-safe CodexUsageFetching fake with an optional one-shot queue (the
/// default result serves once the queue is drained) and an optional blocking
/// gate so tests can hold a fetch in flight.
private final class FakeCodexUsageFetcher: CodexUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let defaultResult: Result<[String: AnyCodableLike], Error>
    private var queued: [Result<[String: AnyCodableLike], Error>] = []
    private var fetchCountStorage = 0
    var onFetchStart: (@Sendable () -> Void)?
    var blockGate: DispatchSemaphore?

    init(result: [String: AnyCodableLike]) {
        defaultResult = .success(result)
    }

    init(error: Error) {
        defaultResult = .failure(error)
    }

    func enqueue(_ result: Result<[String: AnyCodableLike], Error>) {
        lock.lock()
        queued.append(result)
        lock.unlock()
    }

    var fetchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchCountStorage
    }

    func fetchRateLimitsResult() throws -> [String: AnyCodableLike] {
        lock.lock()
        fetchCountStorage += 1
        let result = queued.isEmpty ? defaultResult : queued.removeFirst()
        let onStart = onFetchStart
        let gate = blockGate
        lock.unlock()
        onStart?()
        gate?.wait()
        return try result.get()
    }
}

private final class FakeCodexFallbackReader: CodexRateLimitMonitorReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<[String: AnyCodableLike], Error>
    private var readCountStorage = 0

    init(result: [String: AnyCodableLike]) {
        self.result = .success(result)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return readCountStorage
    }

    func readRateLimits() throws -> [String: AnyCodableLike] {
        lock.lock()
        readCountStorage += 1
        lock.unlock()
        return try result.get()
    }
}

private final class RecordingUsageRefreshScheduler: UsageRefreshScheduling {
    private(set) var interval: TimeInterval?
    private var action: (@MainActor () -> Void)?

    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func stop() {
        action = nil
    }

    @MainActor
    func fire() {
        action?()
    }
}

private extension UsageWindowSlot {
    var snapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .unavailable: return nil
        }
    }

    var staleReason: String? {
        if case .stale(_, let reason) = self { return reason }
        return nil
    }
}

@MainActor
final class UsageStoreRefreshTrackingTests: XCTestCase {
    /// Per-test isolated UserDefaults to avoid polluting the developer's
    /// .standard suite during local `swift test` runs. Mirrors the pattern
    /// already used by UsageStoreTests in this file.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "UsageStoreRefreshTrackingTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Asserts the success path: `isRefreshing` is true while the fetch is
    /// held in flight by the gate, false after. The gate is what proves
    /// enterRefresh fired before the fetch and exitRefresh after it.
    func testRefreshingObservedTrueMidFlightAndFalseAfterSuccess() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler())
        let fetcher = FakeCodexUsageFetcher(result: UsageStoreTests.codexResult(weeklyReset: 100_000))
        let started = expectation(description: "fetch started")
        started.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        fetcher.onFetchStart = { started.fulfill() }
        fetcher.blockGate = gate

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)

        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isRefreshing, "must be true while the OAuth fetch is in flight")
        gate.signal()
        await waitUntilNotRefreshing(store)
        XCTAssertFalse(store.isRefreshing, "must drop to false after success — defer { exitRefresh() } fired")
    }

    /// Same proof pattern, but the fetcher throws. Verifies the defer cleans
    /// up on the failure path — the invariant most likely to regress.
    func testRefreshingObservedTrueMidFlightAndFalseAfterThrownError() async {
        let store = UsageStore(defaults: defaults, scheduler: RecordingUsageRefreshScheduler())
        let fetcher = FakeCodexUsageFetcher(error: NSError(domain: "test", code: 1))
        let started = expectation(description: "fetch started (error path)")
        started.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        fetcher.onFetchStart = { started.fulfill() }
        fetcher.blockGate = gate

        store.startUsageChannels(claude: nil, codex: fetcher, codexFallback: nil)

        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isRefreshing, "must be true while the OAuth fetch is in flight (error path)")
        gate.signal()
        await waitUntilNotRefreshing(store)
        XCTAssertFalse(store.isRefreshing, "must drop to false after thrown error — defer fired in catch")
    }

    private func waitUntilNotRefreshing(_ store: UsageStore, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !store.isRefreshing { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
