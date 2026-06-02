import Darwin
import Foundation
import BoughCore

@MainActor
protocol UsageRateLimitReading: AnyObject {
    func readRateLimits() async throws -> [String: AnyCodableLike]
}

@MainActor
protocol UsageRefreshScheduling: AnyObject {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void)
    func stop()
}

final class TimerUsageRefreshScheduler: UsageRefreshScheduling {
    private var timer: Timer?

    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

enum UsageRefreshActivity: Equatable {
    case active
    case idle
}

enum UsageContinuityWriteMode: Equatable {
    case appOwned
    case helperOwned

    init(defaults: UserDefaults) {
        let raw = defaults.string(forKey: SettingsKey.usageContinuityWriterOwner)
        self = raw == UsageContinuityWriterOwner.helper.rawValue ? .helperOwned : .appOwned
    }
}

@MainActor
@Observable
final class UsageStore {
    private enum Constants {
        static let forecastUnavailableReason = "Usage data is stale"
        static let activeRefreshInterval: TimeInterval = 60
        static let idleRefreshInterval: TimeInterval = 300
        static let sampleFreshnessInterval: TimeInterval = UsageMonitorRunner.sampleFreshnessInterval
        static let appServerUnavailableReason = "Codex app-server unavailable"
        static let usageUnavailableReason = "Codex usage unavailable"
        static let refreshFailedKey = "usage_refresh_failed"
        static let defaultClaudeUsageFilePath = NSHomeDirectory() + "/.bough/claude-usage.json"
        static let defaultClaudeSettingsFilePath = NSHomeDirectory() + "/.claude/settings.json"
        static let claudeHookNotInstalledKey = "usage_claude_hook-not-installed"
        static let claudeHookInstalledNotTriggeredKey = "usage_claude_hook-installed-not-triggered"
        static let claudePayloadMissingRateLimitsKey = "usage_claude_payload-missing-rate-limits"
        static let claudeParseFailureKey = "usage_claude_parse-failure"
        static let claudeStaleKey = "usage_claude_stale"
    }

    @ObservationIgnored
    let defaults: UserDefaults

    @ObservationIgnored
    private let scheduler: UsageRefreshScheduling

    @ObservationIgnored
    let now: () -> Date

    @ObservationIgnored
    let continuityStore: UsageContinuityStore?

    @ObservationIgnored
    let fixedContinuityWriteMode: UsageContinuityWriteMode?

    @ObservationIgnored
    private let claudeUsageFilePath: String

    @ObservationIgnored
    private let claudeSettingsFilePath: String

    @ObservationIgnored
    private let usageMonitorCommandPath: String?

    @ObservationIgnored
    var snapshots: [UsageTool: UsageSnapshot] = [:]

    @ObservationIgnored
    private var inFlightCount: Int = 0 {
        didSet { bumpSnapshotRevision() }
    }

    /// True iff at least one Codex rate-limit refresh is currently in
    /// flight. Computed from a monotonic counter so overlapping refreshes
    /// (manual triggered while loop refresh is mid-flight) don't race.
    /// Wrapped via `enterRefresh()` / `defer { exitRefresh() }` at every
    /// `refreshCodex` entry point so cancellation, errors, and
    /// generation-mismatch early-returns all decrement correctly.
    var isRefreshing: Bool {
        _ = snapshotRevision  // observation hook — re-read when revision bumps
        #if DEBUG
        return inFlightCount > 0 || debugForceIsRefreshing
        #else
        return inFlightCount > 0
        #endif
    }

    private func enterRefresh() {
        inFlightCount += 1
    }

    private func exitRefresh() {
        inFlightCount = max(0, inFlightCount - 1)
    }

    #if DEBUG
    /// Debug-only override that lets `UsageDebugPresets.refreshing` simulate
    /// a refresh-in-flight without actually issuing network I/O. Setter
    /// triggers a snapshot revision bump so observers re-render.
    var debugForceIsRefreshing: Bool = false {
        didSet { bumpSnapshotRevision() }
    }

    /// Debug-only override that lets `UsageDebugPresets.firstLaunchBaselineGap`
    /// surface the Settings → Usage inline "Today reflects post-launch usage"
    /// notice (TODAY-11 / D-14) without requiring the manual smoke step of
    /// deleting ~/.bough/usage-daily.json between launches. ORed into
    /// `isFirstLaunchBaseline(for:)`. Cleared by `UsageDebugPresets
    /// .clearOverrides(store:)`.
    var debugForceFirstLaunchNotice: Bool = false {
        didSet { bumpSnapshotRevision() }
    }
    #endif

    private var snapshotRevision = 0

    @ObservationIgnored
    private weak var codexReader: UsageRateLimitReading?

    @ObservationIgnored
    private var refreshGeneration = 0

    @ObservationIgnored
    private var loopRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var inFlightCodexRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private weak var inFlightCodexRefreshReader: UsageRateLimitReading?

    @ObservationIgnored
    private var inFlightCodexRefreshGeneration: Int?

    @ObservationIgnored
    private var inFlightCodexRefreshToken: UUID?

    @ObservationIgnored
    private var codexRefreshActivity: UsageRefreshActivity = .active

    @ObservationIgnored
    private var claudeUsageWatcher: DispatchSourceFileSystemObject?

    /// Owns the per-tool daily-allowance baseline (Phase 5 plan 01 — D-16).
    /// Single owner across the store lifetime; recordTick fires on every snapshot
    /// refresh BEFORE we hand the (live weekly, baseline) pair to the calculator.
    @ObservationIgnored
    private let dailyAccumulator = UsageDailyAccumulator()

    var selectedTool: UsageTool {
        didSet {
            guard Self.selectableUsageTools.contains(selectedTool) else {
                selectedTool = .codex
                return
            }
            defaults.set(selectedTool.rawValue, forKey: SettingsKey.usageSelectedProvider)
        }
    }

    var selectableTools: [UsageTool] {
        displayableTools
    }

    var displayableTools: [UsageTool] {
        Self.selectableUsageTools.filter { usageDisplayEnabled(tool: $0) }
    }

    var selectedDisplayTool: UsageTool? {
        let tools = displayableTools
        if tools.contains(selectedTool) { return selectedTool }
        return tools.first
    }

    private static let selectableUsageTools = UsageTool.selectableQuotaProviders

    init(
        defaults: UserDefaults = .standard,
        scheduler: UsageRefreshScheduling,
        monitorClaudeCode: Bool = true,
        claudeUsageFilePath: String = Constants.defaultClaudeUsageFilePath,
        claudeSettingsFilePath: String = Constants.defaultClaudeSettingsFilePath,
        usageMonitorCommandPath: String? = nil,
        now: @escaping () -> Date = Date.init,
        continuityStore: UsageContinuityStore? = nil,
        continuityWriteMode: UsageContinuityWriteMode? = nil,
        codingSessionsEnabled: Bool? = nil
    ) {
        self.defaults = defaults
        self.scheduler = scheduler
        self.claudeUsageFilePath = claudeUsageFilePath
        self.claudeSettingsFilePath = claudeSettingsFilePath
        self.usageMonitorCommandPath = usageMonitorCommandPath ?? (defaults === UserDefaults.standard ? UsageMonitorRunner.defaultCommandPath() : nil)
        self.now = now
        self.continuityStore = continuityStore
        self.fixedContinuityWriteMode = continuityWriteMode

        let persistedTool = defaults.string(forKey: SettingsKey.usageSelectedProvider)
            .flatMap(UsageTool.init(rawValue:))
            ?? .codex
        let initialTool = Self.selectableUsageTools.contains(persistedTool) ? persistedTool : .codex
        self.selectedTool = initialTool
        if initialTool != persistedTool {
            defaults.set(initialTool.rawValue, forKey: SettingsKey.usageSelectedProvider)
        }
        normalizeSelectedToolForDisplayPreferences()

        let productModeEnabled = codingSessionsEnabled ?? CodingSessionsSettings.isEnabled(defaults: defaults)
        guard productModeEnabled else {
            writeUsageMonitorCommand(enabledTools: [])
            return
        }

        startCodingSessionCollection(monitorClaudeCode: monitorClaudeCode)
    }

    private func startCodingSessionCollection(monitorClaudeCode: Bool) {
        writeUsageMonitorCommand()

        if snapshots[.claudeCode] == nil {
            snapshots[.claudeCode] = UsageSnapshot.claudeUnavailable(now: now())
            bumpSnapshotRevision()
        }
        if snapshots[.codex] == nil {
            snapshots[.codex] = UsageSnapshot(
                tool: .codex,
                planName: nil,
                fiveHour: .loading,
                weekly: .loading,
                today: nil,
                availability: .loading,
                lastRefresh: nil
            )
            bumpSnapshotRevision()
        }

        restoreContinuityStateIfAvailable()

        if monitorClaudeCode && defaults === UserDefaults.standard {
            refreshClaudeCodeUsageFromDisk()
            startClaudeCodeUsageWatcher()
        }
    }

    convenience init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            scheduler: TimerUsageRefreshScheduler(),
            now: now,
            continuityStore: UsageContinuityStore.liveOrNil()
        )
    }

    func snapshot(for tool: UsageTool) -> UsageSnapshot {
        _ = snapshotRevision
        #if DEBUG
        if let preset = debugPreset {
            return UsageDebugPresets.snapshot(for: preset, tool: tool, now: now())
        }
        #endif
        if let snapshot = snapshots[tool] {
            return snapshot
        }

        switch tool {
        case .claudeCode:
            return UsageSnapshot.claudeUnavailable(now: now())
        case .codex:
            return UsageSnapshot(
                tool: .codex,
                planName: nil,
                fiveHour: .loading,
                weekly: .loading,
                today: nil,
                availability: .loading,
                lastRefresh: nil
            )
        }
    }

    /// Pass-through to the accumulator's first-launch flag (TODAY-11 / D-13).
    /// Settings consumes this to render the inline "Today reflects post-launch
    /// usage" notice. Never persisted — auto-disappears at next local-midnight
    /// rollover.
    ///
    /// In DEBUG builds, ORed with `debugForceFirstLaunchNotice` so the
    /// `firstLaunchBaselineGap` debug preset can surface the notice without
    /// requiring the manual `rm ~/.bough/usage-daily.json` step.
    func isFirstLaunchBaseline(for tool: UsageTool) -> Bool {
        #if DEBUG
        if debugForceFirstLaunchNotice { return true }
        #endif
        return dailyAccumulator.isFirstLaunch(for: tool)
    }

    func usageDisplayEnabled(tool: UsageTool) -> Bool {
        defaultTrueBool(forKey: SettingsKey.usageDisplayEnabled(tool.rawValue))
    }

    func setUsageDisplayEnabled(tool: UsageTool, isEnabled: Bool) {
        defaults.set(isEnabled, forKey: SettingsKey.usageDisplayEnabled(tool.rawValue))
        normalizeSelectedToolForDisplayPreferences()
        bumpSnapshotRevision()
    }

    func usageStatisticsEnabled(tool: UsageTool) -> Bool {
        defaultTrueBool(forKey: SettingsKey.usageStatisticsEnabled(tool.rawValue))
    }

    func setUsageStatisticsEnabled(tool: UsageTool, isEnabled: Bool) {
        defaults.set(isEnabled, forKey: SettingsKey.usageStatisticsEnabled(tool.rawValue))
        writeUsageMonitorCommand()
        bumpSnapshotRevision()
    }

    func continuityDailyState(for tool: UsageTool) -> UsageContinuityDailyState? {
        guard let continuityStore,
              let localDate = snapshots[tool]?.today?.basis.localDate else {
            return nil
        }
        return try? continuityStore.latestDailyState(tool: tool, localDate: localDate)
    }

    func recoveryReminderPreference(tool: UsageTool, windowKind: UsageWindowKind) -> UsageRecoveryReminderPreference {
        (try? continuityStore?.recoveryReminderPreference(tool: tool, windowKind: windowKind)) ?? UsageRecoveryReminderPreference(
            tool: tool,
            windowKind: windowKind,
            isEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func setRecoveryReminderPreference(tool: UsageTool, windowKind: UsageWindowKind, isEnabled: Bool) {
        try? continuityStore?.setRecoveryReminderPreference(
            tool: tool,
            windowKind: windowKind,
            isEnabled: isEnabled,
            updatedAt: now()
        )
        bumpSnapshotRevision()
    }

    func thresholdNotificationPreference(tool: UsageTool) -> UsageThresholdNotificationPreference {
        (try? continuityStore?.thresholdNotificationPreference(tool: tool)) ?? UsageThresholdNotificationPreference(
            tool: tool,
            isEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func setThresholdNotificationsMasterEnabled(_ isEnabled: Bool) {
        try? continuityStore?.setThresholdNotificationsMasterEnabled(isEnabled: isEnabled, updatedAt: now())
        bumpSnapshotRevision()
    }

    func thresholdNotificationsMasterEnabled() -> Bool {
        (try? continuityStore?.thresholdNotificationsMasterEnabled()) ?? false
    }

    func setThresholdNotificationPreference(tool: UsageTool, isEnabled: Bool) {
        try? continuityStore?.setThresholdNotificationPreference(
            tool: tool,
            isEnabled: isEnabled,
            updatedAt: now()
        )
        bumpSnapshotRevision()
    }

    private func defaultTrueBool(forKey key: String) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    private func normalizeSelectedToolForDisplayPreferences() {
        let tools = displayableTools
        guard !tools.isEmpty, !tools.contains(selectedTool) else { return }
        selectedTool = tools.first ?? selectedTool
    }

    private func writeUsageMonitorCommand(enabledTools overrideEnabledTools: [UsageTool]? = nil) {
        guard let usageMonitorCommandPath else { return }
        let enabledTools = overrideEnabledTools ?? Self.selectableUsageTools.filter { usageStatisticsEnabled(tool: $0) }
        let command = UsageMonitorCommand(enabledTools: enabledTools)
        let url = URL(fileURLWithPath: usageMonitorCommandPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(command).write(to: url, options: .atomic)
        } catch {
            // The helper command file is advisory. App-side preferences remain
            // authoritative and will be re-synced on the next settings change.
        }
    }

    func recoveryEdgeRecords(for tool: UsageTool) -> [UsageRecoveryEdgeRecord] {
        (try? continuityStore?.recoveryEdgeRecords(tool: tool)) ?? []
    }

    #if DEBUG
    /// In-memory only; not persisted. Settings → Usage debug picker writes here.
    var debugPreset: UsageDebugPresets.Preset? {
        didSet { bumpSnapshotRevision() }
    }
    #endif

    func startCodexRefreshLoop(using reader: UsageRateLimitReading?) {
        scheduler.stop()
        cancelLoopRefreshTask()
        refreshGeneration += 1
        let generation = refreshGeneration

        guard let reader else {
            codexReader = nil
            markCodexUnavailable(reason: Constants.appServerUnavailableReason)
            return
        }

        codexReader = reader
        scheduleCodexRefreshLoop(using: reader, generation: generation)

        startLoopRefresh(using: reader, generation: generation)
    }

    func setCodexRefreshActivity(_ activity: UsageRefreshActivity) {
        guard codexRefreshActivity != activity else { return }
        codexRefreshActivity = activity
        guard let reader = codexReader else { return }
        scheduleCodexRefreshLoop(using: reader, generation: refreshGeneration)
    }

    private func scheduleCodexRefreshLoop(using reader: UsageRateLimitReading, generation: Int) {
        scheduler.start(every: refreshInterval(for: codexRefreshActivity)) { [weak self] in
            guard let self else { return }
            self.startLoopRefresh(using: reader, generation: generation)
        }
    }

    private func refreshInterval(for activity: UsageRefreshActivity) -> TimeInterval {
        switch activity {
        case .active: return Constants.activeRefreshInterval
        case .idle: return Constants.idleRefreshInterval
        }
    }

    func stopCodexRefreshLoop() {
        scheduler.stop()
        cancelLoopRefreshTask()
        refreshGeneration += 1
        codexReader = nil
        markCodexUnavailable(reason: Constants.appServerUnavailableReason)
    }

    func pauseCodingSessionCollectionForDisabledMode() {
        scheduler.stop()
        cancelLoopRefreshTask()
        refreshGeneration += 1
        codexReader = nil
        stopClaudeCodeUsageWatcher()
        snapshots.removeValue(forKey: .codex)
        snapshots.removeValue(forKey: .claudeCode)
        writeUsageMonitorCommand(enabledTools: [])
        bumpSnapshotRevision()
    }

    func resumeCodingSessionCollectionForEnabledMode(monitorClaudeCode: Bool = true) {
        startCodingSessionCollection(monitorClaudeCode: monitorClaudeCode)
    }

    @discardableResult
    func refreshClaudeCodeUsageFromDisk(markRefreshAttempt: Bool = false) -> Bool {
        let url = URL(fileURLWithPath: claudeUsageFilePath)
        guard FileManager.default.fileExists(atPath: claudeUsageFilePath) else {
            let reason = claudeStatusLineHookIsInstalled()
                ? localized(Constants.claudeHookInstalledNotTriggeredKey)
                : localized(Constants.claudeHookNotInstalledKey)
            markClaudeCodeUnavailable(reason: reason)
            return false
        }

        do {
            let data = try Data(contentsOf: url)
            let fileMtime = try FileManager.default
                .attributesOfItem(atPath: claudeUsageFilePath)[.modificationDate] as? Date
            return applyClaudeCodePayload(data, receivedAt: fileMtime ?? now())
        } catch {
            markClaudeCodeUnavailable(reason: localized(Constants.claudeParseFailureKey))
            return false
        }
    }

    func startClaudeCodeUsageWatcher() {
        claudeUsageWatcher?.cancel()
        claudeUsageWatcher = nil

        let directory = (claudeUsageFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                _ = self?.refreshClaudeCodeUsageFromDisk()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        claudeUsageWatcher = source
        source.resume()
    }

    func stopClaudeCodeUsageWatcher() {
        claudeUsageWatcher?.cancel()
        claudeUsageWatcher = nil
    }

    @discardableResult
    func applyClaudeCodePayload(_ data: Data, receivedAt: Date? = nil) -> Bool {
        let currentDate = receivedAt ?? now()
        switch claudePayloadRateLimitStatus(data) {
        case .present:
            break
        case .missing:
            markClaudeCodeUnavailable(reason: localized(Constants.claudePayloadMissingRateLimitsKey))
            return false
        case .invalid:
            markClaudeCodeUnavailable(reason: localized(Constants.claudeParseFailureKey))
            return false
        }
        guard let parsed = ClaudeCodeRateLimitParser.parse(data: data, receivedAt: currentDate) else {
            markClaudeCodeUnavailable(reason: localized(Constants.claudeParseFailureKey))
            return false
        }

        let priorWeekly = acceptedWeeklySnapshot(for: .claudeCode)
        let sourceIsFresh = now().timeIntervalSince(currentDate) <= Constants.sampleFreshnessInterval
        let today: TodayValue? = {
            guard sourceIsFresh else { return nil }
            guard case .available(let weekly) = parsed.weekly else { return nil }
            let calendar = Calendar.current
            let timeZone = TimeZone.current
            dailyAccumulator.recordTick(
                weekly: weekly,
                tool: .claudeCode,
                now: currentDate,
                calendar: calendar,
                timeZone: timeZone
            )
            return UsageForecastCalculator.forecast(
                weekly: weekly,
                baseline: dailyAccumulator.baseline(for: .claudeCode),
                priorWeekly: priorWeekly,
                now: currentDate,
                calendar: calendar,
                timeZone: timeZone
            )
        }()

        let snapshot = UsageSnapshot(
            tool: .claudeCode,
            planName: parsed.planName,
            fiveHour: parsed.fiveHour,
            weekly: parsed.weekly,
            today: today,
            availability: parsed.availability,
            lastRefresh: parsed.lastRefresh
        )
        snapshots[.claudeCode] = sourceIsFresh
            ? snapshot
            : snapshot.markingStale(reason: Constants.forecastUnavailableReason)
        persistContinuitySnapshot(for: .claudeCode)
        bumpSnapshotRevision()
        return true
    }

    func refreshCodex(using reader: UsageRateLimitReading?) async {
        guard let reader else {
            markCodexUnavailable(reason: Constants.appServerUnavailableReason)
            return
        }

        let activeReader = codexReader
        let generation = activeReader == nil ? nil : refreshGeneration
        await refreshCodex(using: reader, expectedGeneration: generation, expectedReader: activeReader)
    }

    private func startLoopRefresh(using reader: UsageRateLimitReading, generation: Int) {
        if inFlightCodexRefreshTask != nil,
           inFlightCodexRefreshReader === reader,
           inFlightCodexRefreshGeneration == generation {
            return
        }

        loopRefreshTask?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshCodex(using: reader, expectedGeneration: generation, expectedReader: reader)

            guard !Task.isCancelled else { return }
            if self.refreshGeneration == generation {
                self.loopRefreshTask = nil
            }
        }

        loopRefreshTask = task
    }

    private func cancelLoopRefreshTask() {
        loopRefreshTask?.cancel()
        loopRefreshTask = nil
        inFlightCodexRefreshTask?.cancel()
        inFlightCodexRefreshTask = nil
        inFlightCodexRefreshReader = nil
        inFlightCodexRefreshGeneration = nil
        inFlightCodexRefreshToken = nil
    }

    private func refreshCodex(
        using reader: UsageRateLimitReading?,
        expectedGeneration: Int?,
        expectedReader: UsageRateLimitReading?
    ) async {
        guard let reader else {
            markCodexUnavailable(reason: Constants.appServerUnavailableReason)
            return
        }

        if let task = inFlightCodexRefreshTask,
           inFlightCodexRefreshReader === reader,
           inFlightCodexRefreshGeneration == expectedGeneration {
            await task.value
            return
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCodexRefresh(
                using: reader,
                expectedGeneration: expectedGeneration,
                expectedReader: expectedReader
            )
        }
        inFlightCodexRefreshTask = task
        inFlightCodexRefreshReader = reader
        inFlightCodexRefreshGeneration = expectedGeneration
        inFlightCodexRefreshToken = token

        await task.value

        if inFlightCodexRefreshToken == token {
            inFlightCodexRefreshTask = nil
            inFlightCodexRefreshReader = nil
            inFlightCodexRefreshGeneration = nil
            inFlightCodexRefreshToken = nil
        }
    }

    private func performCodexRefresh(
        using reader: UsageRateLimitReading,
        expectedGeneration: Int?,
        expectedReader: UsageRateLimitReading?
    ) async {
        enterRefresh()
        defer { exitRefresh() }

        if Task.isCancelled { return }

        do {
            let result = try await reader.readRateLimits()
            if Task.isCancelled { return }
            if let expectedReader, codexReader !== expectedReader { return }
            guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
            let didApplyResult = applyCodexRateLimitResult(result)
            if !didApplyResult {
                markCodexUnavailable(reason: localized(Constants.refreshFailedKey))
            }
        } catch {
            if Task.isCancelled { return }
            if let expectedReader, codexReader !== expectedReader { return }
            guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
            markCodexUnavailable(reason: localized(Constants.refreshFailedKey))
        }
    }

    @discardableResult
    func applyCodexRateLimitResult(_ result: [String: AnyCodableLike]) -> Bool {
        let response = CodexJSONRPCMessage(raw: ["result": .object(result)], kind: .response(id: .string("usage")))
        return applyCodexRateLimitMessage(response)
    }

    @discardableResult
    func applyCodexRateLimitMessage(_ message: CodexJSONRPCMessage) -> Bool {
        let currentDate = now()
        guard let parsed = CodexRateLimitParser.parse(message: message, receivedAt: currentDate) else {
            return false
        }

        let isWeeklyStale = {
            if case .available(let weeklySnapshot) = parsed.weekly {
                return weeklySnapshot.resetsAt <= currentDate
            }
            return false
        }()

        if isWeeklyStale {
            let staleSnapshot = UsageSnapshot(
                tool: parsed.tool,
                planName: parsed.planName,
                fiveHour: parsed.fiveHour,
                weekly: parsed.weekly.staled(reason: Constants.forecastUnavailableReason),
                today: nil,
                availability: .stale(reason: Constants.forecastUnavailableReason),
                lastRefresh: parsed.lastRefresh
            )
            snapshots[.codex] = staleSnapshot
            bumpSnapshotRevision()
            return true
        }

        // A3' wiring (Phase 5 plan 05-02 / D-16):
        //   1. accumulator records the baseline FIRST (it owns cross-midnight,
        //      TZ-change, and first-launch keying — Phase 5 plan 05-01),
        //   2. calculator then reads the (now-valid) baseline plus the live
        //      weekly snapshot to produce TodayValue.
        let priorWeekly = acceptedWeeklySnapshot(for: parsed.tool)
        let today: TodayValue? = {
            guard case .available(let weekly) = parsed.weekly else { return nil }
            let calendar = Calendar.current
            let timeZone = TimeZone.current
            dailyAccumulator.recordTick(
                weekly: weekly,
                tool: parsed.tool,
                now: currentDate,
                calendar: calendar,
                timeZone: timeZone
            )
            return UsageForecastCalculator.forecast(
                weekly: weekly,
                baseline: dailyAccumulator.baseline(for: parsed.tool),
                priorWeekly: priorWeekly,
                now: currentDate,
                calendar: calendar,
                timeZone: timeZone
            )
        }()

        snapshots[.codex] = UsageSnapshot(
            tool: parsed.tool,
            planName: parsed.planName,
            fiveHour: parsed.fiveHour,
            weekly: parsed.weekly,
            today: today,
            availability: parsed.availability,
            lastRefresh: parsed.lastRefresh
        )
        persistContinuitySnapshot(for: parsed.tool)
        bumpSnapshotRevision()
        return true
    }

    private func restoreContinuityStateIfAvailable() {
        guard let continuityStore else { return }
        _ = try? continuityStore.importLegacyBaselines(dailyAccumulator.baselines, migratedAt: now())
        let currentLocalDate = Self.formattedYYYYMMDD(now(), timeZone: TimeZone.current)
        for tool in Self.selectableUsageTools {
            if let restored = try? continuityStore.latestSnapshot(tool: tool) {
                snapshots[tool] = restored
            }
            // V040-QUAL-01: when usage-daily.json is missing or stale for today,
            // hydrate the accumulator from SQLite's authoritative daily_state row
            // so the first fresh sample does not reseed the day-start baseline at
            // the live weekly.usedPercent and force pct=100 (Phase 24 continuity
            // contract: SQLite is source of truth; JSON is legacy cache).
            let jsonBaseline = dailyAccumulator.baseline(for: tool)
            if jsonBaseline?.localDate != currentLocalDate,
               let dailyState = try? continuityStore.latestDailyState(tool: tool, localDate: currentLocalDate) {
                let restoredBaseline = DailyBaseline(
                    tool: tool,
                    localDate: dailyState.localDate,
                    weeklyUsedAtDayStart: dailyState.weeklyUsedAtDayStart,
                    todayAllowanceOfWeek: dailyState.todayAllowanceOfWeek,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    capturedAt: dailyState.capturedAt
                )
                dailyAccumulator.restoreBaseline(restoredBaseline, for: tool)
            }
        }
        bumpSnapshotRevision()
    }

    private func acceptedWeeklySnapshot(for tool: UsageTool) -> UsageWindowSnapshot? {
        guard let snapshot = snapshots[tool],
              case .available(let weekly) = snapshot.weekly else {
            return nil
        }
        return weekly
    }

    func evaluateStaleness() {
        evaluateCodexStaleness()
        evaluateClaudeCodeStaleness()
    }

    private func evaluateCodexStaleness() {
        guard var snapshot = snapshots[.codex] else { return }
        guard let lastRefresh = snapshot.lastRefresh else { return }
        let stale = now().timeIntervalSince(lastRefresh) > Constants.sampleFreshnessInterval
        guard stale else { return }

        snapshot = UsageSnapshot(
            tool: snapshot.tool,
            planName: snapshot.planName,
            fiveHour: snapshot.fiveHour.staled(reason: Constants.forecastUnavailableReason),
            weekly: snapshot.weekly.staled(reason: Constants.forecastUnavailableReason),
            today: nil,
            availability: .stale(reason: Constants.forecastUnavailableReason),
            lastRefresh: snapshot.lastRefresh
        )

        snapshots[.codex] = snapshot
        bumpSnapshotRevision()
    }

    private func evaluateClaudeCodeStaleness() {
        guard var snapshot = snapshots[.claudeCode] else { return }
        guard let lastRefresh = snapshot.lastRefresh else { return }
        let stale = now().timeIntervalSince(lastRefresh) > Constants.sampleFreshnessInterval
        guard stale else { return }

        let reason = localized(Constants.claudeStaleKey)
        snapshot = UsageSnapshot(
            tool: snapshot.tool,
            planName: snapshot.planName,
            fiveHour: snapshot.fiveHour.staled(reason: reason),
            weekly: snapshot.weekly.staled(reason: reason),
            today: nil,
            availability: .stale(reason: reason),
            lastRefresh: snapshot.lastRefresh
        )

        snapshots[.claudeCode] = snapshot
        bumpSnapshotRevision()
    }

    func markCodexUnavailable(reason: String) {
        guard let snapshot = snapshots[.codex] else {
            snapshots[.codex] = UsageSnapshot(
                tool: .codex,
                planName: nil,
                fiveHour: .unavailable(reason: reason),
                weekly: .unavailable(reason: reason),
                today: nil,
                availability: .unavailable(reason: reason),
                lastRefresh: nil
            )
            bumpSnapshotRevision()
            return
        }

        if snapshot.fiveHour.hasData || snapshot.weekly.hasData {
            snapshots[.codex] = UsageSnapshot(
                tool: .codex,
                planName: snapshot.planName,
                fiveHour: snapshot.fiveHour.staled(reason: reason),
                weekly: snapshot.weekly.staled(reason: reason),
                today: nil,
                availability: .stale(reason: reason),
                lastRefresh: snapshot.lastRefresh
            )
            bumpSnapshotRevision()
            return
        }

        snapshots[.codex] = UsageSnapshot(
            tool: .codex,
            planName: nil,
            fiveHour: .unavailable(reason: reason),
            weekly: .unavailable(reason: reason),
            today: nil,
            availability: .unavailable(reason: reason),
            lastRefresh: snapshot.lastRefresh
        )
        bumpSnapshotRevision()
    }

    private func markClaudeCodeUnavailable(reason: String) {
        guard let snapshot = snapshots[.claudeCode] else {
            snapshots[.claudeCode] = UsageSnapshot(
                tool: .claudeCode,
                planName: nil,
                fiveHour: .unavailable(reason: reason),
                weekly: .unavailable(reason: reason),
                today: nil,
                availability: .unavailable(reason: reason),
                lastRefresh: nil
            )
            bumpSnapshotRevision()
            return
        }

        if snapshot.fiveHour.hasData || snapshot.weekly.hasData {
            snapshots[.claudeCode] = UsageSnapshot(
                tool: .claudeCode,
                planName: snapshot.planName,
                fiveHour: snapshot.fiveHour.staled(reason: reason),
                weekly: snapshot.weekly.staled(reason: reason),
                today: nil,
                availability: .stale(reason: reason),
                lastRefresh: snapshot.lastRefresh
            )
            bumpSnapshotRevision()
            return
        }

        snapshots[.claudeCode] = UsageSnapshot(
            tool: .claudeCode,
            planName: nil,
            fiveHour: .unavailable(reason: reason),
            weekly: .unavailable(reason: reason),
            today: nil,
            availability: .unavailable(reason: reason),
            lastRefresh: snapshot.lastRefresh
        )
        bumpSnapshotRevision()
    }

    /// DIAG-01: Called when hook health check fails on launch. Sets claudeCode snapshot
    /// availability to .partial so UsageStatusDotClassifier produces .yellowSteady.
    ///
    /// First-run nil-snapshot trade-off (DIAG-01 acceptance): If snapshots[.claudeCode] is nil
    /// (no prior Claude payload yet — typical on first launch after install), this is a no-op.
    /// The notch dot stays in its "loading/unknown" state for a fresh-install rather than showing
    /// amber for a missing-data case. On first launch there is no "stranded" state to recover from;
    /// the user is in a normal pre-first-payload window. Once the first payload arrives, subsequent
    /// health-check failures DO produce the amber state correctly. This trade-off is explicit and
    /// accepted; creating a synthetic partial snapshot on first-run failure would produce a flicker
    /// artifact and conflict with the "no synthetic data" invariant.
    func markClaudeCodeHookDisconnected() {
        guard let snapshot = snapshots[.claudeCode] else { return }
        snapshots[.claudeCode] = UsageSnapshot(
            tool: .claudeCode,
            planName: snapshot.planName,
            fiveHour: snapshot.fiveHour,
            weekly: snapshot.weekly,
            today: snapshot.today,
            availability: .partial(reason: "Hook disconnected"),
            lastRefresh: snapshot.lastRefresh
        )
        bumpSnapshotRevision()
    }

    /// DIAG-01 inverse: Plan 17-05's Retry button calls this on a successful re-check
    /// to flip availability back from .partial to .available without waiting for the
    /// next hook payload to clear the amber dot.
    func clearClaudeCodeHookDisconnect() {
        guard let snapshot = snapshots[.claudeCode] else { return }
        // Only clear if currently .partial — leave .available untouched, do not
        // resurrect data when nothing was there.
        if case .partial = snapshot.availability {
            snapshots[.claudeCode] = UsageSnapshot(
                tool: .claudeCode,
                planName: snapshot.planName,
                fiveHour: snapshot.fiveHour,
                weekly: snapshot.weekly,
                today: snapshot.today,
                availability: .available,
                lastRefresh: snapshot.lastRefresh
            )
            bumpSnapshotRevision()
        }
    }

    private enum ClaudePayloadRateLimitStatus {
        case present
        case missing
        case invalid
    }

    private func claudePayloadRateLimitStatus(_ data: Data) -> ClaudePayloadRateLimitStatus {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let root = AnyCodableLike.from(raw).asObject else {
            return .invalid
        }
        return root["rate_limits"]?.asObject == nil ? .missing : .present
    }

    private func claudeStatusLineHookIsInstalled() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command.contains("bough-statusline-bridge.sh")
    }

    private func localized(_ key: String) -> String {
        L10n.shared[key]
    }

    private func bumpSnapshotRevision() {
        snapshotRevision += 1
    }
}

private extension UsageSnapshot {
    func windowSlot(for kind: UsageWindowKind) -> UsageWindowSlot {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        }
    }
}

private extension UsageWindowSlot {
    var acceptedForRecovery: UsageWindowSlot {
        switch self {
        case .available:
            return self
        case .stale(let snapshot, _):
            return .available(snapshot)
        case .loading, .unavailable:
            return self
        }
    }

    var availableSnapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot):
            return snapshot
        case .loading, .stale, .unavailable:
            return nil
        }
    }

    func staled(reason: String) -> UsageWindowSlot {
        switch self {
        case .available(let snapshot):
            return .stale(snapshot, reason: reason)
        case .stale(let snapshot, _):
            return .stale(snapshot, reason: reason)
        case .loading, .unavailable:
            return self
        }
    }
}
