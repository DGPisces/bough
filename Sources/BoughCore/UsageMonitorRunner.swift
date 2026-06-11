import Foundation

public final class UsageMonitorRunner {
    public static let appClosedIdleInterval: TimeInterval = 300
    public static let sampleFreshnessInterval: TimeInterval = 900
    public static let sampleFutureSkewAllowance: TimeInterval = 60
    public static let staleSampleReason = "Usage data is stale"

    public static func sampleTimestampIsFresh(receivedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(receivedAt)
        return age >= -sampleFutureSkewAllowance && age <= sampleFreshnessInterval
    }

    public static func defaultClaudeUsageFilePath() -> String {
        AtomicJSONStore.baseDirectoryURL()
            .appendingPathComponent("claude-usage.json")
            .path
    }

    public static func defaultStatusPath() -> String {
        AtomicJSONStore.baseDirectoryURL()
            .appendingPathComponent("usage-monitor-status.json")
            .path
    }

    public static func defaultCommandPath() -> String {
        AtomicJSONStore.baseDirectoryURL()
            .appendingPathComponent("usage-monitor-command.json")
            .path
    }

    private let continuityStore: UsageContinuityStore
    private let dailyAccumulator: UsageDailyAccumulator
    private let claudeUsageFilePath: String
    private let statusPath: String
    private let commandPath: String
    private let codexRateLimitReader: CodexRateLimitMonitorReading?
    private let claudeOAuthFetcher: ClaudeUsageFetching?
    private let codexOAuthFetcher: CodexUsageFetching?
    private let claudeMirrorFreshness: TimeInterval
    private let now: () -> Date
    private let calendar: Calendar
    private let timeZone: TimeZone
    private let fileManager: FileManager

    public init(
        continuityStore: UsageContinuityStore,
        dailyAccumulator: UsageDailyAccumulator = UsageDailyAccumulator(),
        claudeUsageFilePath: String? = nil,
        statusPath: String? = nil,
        commandPath: String? = nil,
        codexRateLimitReader: CodexRateLimitMonitorReading? = CodexAppServerRateLimitMonitorReader(),
        claudeOAuthFetcher: ClaudeUsageFetching? = nil,
        codexOAuthFetcher: CodexUsageFetching? = nil,
        /// Mirror freshness window (spec §6.2): payload younger than this means the
        /// app is actively polling — use the file and skip the network round trip.
        claudeMirrorFreshness: TimeInterval = 420,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) {
        self.continuityStore = continuityStore
        self.dailyAccumulator = dailyAccumulator
        self.claudeUsageFilePath = claudeUsageFilePath ?? Self.defaultClaudeUsageFilePath()
        self.statusPath = statusPath ?? Self.defaultStatusPath()
        self.commandPath = commandPath ?? Self.defaultCommandPath()
        self.codexRateLimitReader = codexRateLimitReader
        self.claudeOAuthFetcher = claudeOAuthFetcher
        self.codexOAuthFetcher = codexOAuthFetcher
        self.claudeMirrorFreshness = claudeMirrorFreshness
        self.now = now
        self.calendar = calendar
        self.timeZone = timeZone
        self.fileManager = fileManager

        // V040-QUAL-01: symmetric cold-start hydration for the helper-owned
        // writer. Mirrors UsageStore.restoreContinuityStateIfAvailable so the
        // helper's accumulator inherits SQLite's day-start baseline when the
        // legacy usage-daily.json cache is absent or stale.
        let currentLocalDate = Self.formattedYYYYMMDD(now(), calendar: calendar, timeZone: timeZone)
        for tool in UsageTool.selectableQuotaProviders {
            let jsonBaseline = dailyAccumulator.baseline(for: tool)
            if jsonBaseline?.localDate != currentLocalDate,
               let dailyState = try? continuityStore.latestDailyState(tool: tool, localDate: currentLocalDate) {
                let restored = DailyBaseline(
                    tool: tool,
                    localDate: dailyState.localDate,
                    weeklyUsedAtDayStart: dailyState.weeklyUsedAtDayStart,
                    todayAllowanceOfWeek: dailyState.todayAllowanceOfWeek,
                    timeZoneIdentifier: timeZone.identifier,
                    capturedAt: dailyState.capturedAt
                )
                dailyAccumulator.restoreBaseline(restored, for: tool)
            }
        }
    }

    private static func formattedYYYYMMDD(_ date: Date, calendar: Calendar, timeZone: TimeZone) -> String {
        var localCal = calendar
        localCal.timeZone = timeZone
        let c = localCal.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return "1970-01-01" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    @discardableResult
    public func runOnce() -> [UsageMonitorRunOutcome] {
        let outcomes = [
            runCodexOnce(),
            runClaudeCodeOnce()
        ]
        writeCycleStatus(for: outcomes, heartbeatAt: now())
        return outcomes
    }

    @discardableResult
    public func runCodexOnce() -> UsageMonitorRunOutcome {
        guard usageProviderIsEnabled(.codex) else {
            let outcome = UsageMonitorRunOutcome.skipped(tool: .codex)
            writeStatus(for: outcome, heartbeatAt: now())
            return outcome
        }

        if let codexOAuthFetcher {
            do {
                let result = try codexOAuthFetcher.fetchRateLimitsResult()
                return acceptCodexRateLimitResult(result, receivedAt: now())
            } catch let error as OAuthUsageError where error.isAuthFailure {
                // Auth-class failure → fall through to the CLI spawn below so codex
                // can self-heal its credentials (spec §5.3).
            } catch {
                let outcome = UsageMonitorRunOutcome.failed(reason: "Codex usage source read failed")
                writeStatus(for: outcome, heartbeatAt: now())
                return outcome
            }
        }

        guard let codexRateLimitReader else {
            let outcome = UsageMonitorRunOutcome.unavailable(reason: "Codex usage source unavailable")
            writeStatus(for: outcome, heartbeatAt: now())
            return outcome
        }

        do {
            let result = try codexRateLimitReader.readRateLimits()
            return acceptCodexRateLimitResult(result, receivedAt: now())
        } catch let error as CodexAppServerError {
            let outcome: UsageMonitorRunOutcome
            switch error {
            case .executableMissing:
                outcome = .unavailable(reason: "Codex usage source unavailable")
            case .processLaunchFailed, .notConnected, .writeFailed:
                outcome = .failed(reason: "Codex usage source read failed")
            }
            writeStatus(for: outcome, heartbeatAt: now())
            return outcome
        } catch CodexRateLimitMonitorReaderError.requestTimedOut {
            let outcome = UsageMonitorRunOutcome.failed(reason: "Codex usage source timed out")
            writeStatus(for: outcome, heartbeatAt: now())
            return outcome
        } catch {
            let outcome = UsageMonitorRunOutcome.failed(reason: "Codex usage source read failed")
            writeStatus(for: outcome, heartbeatAt: now())
            return outcome
        }
    }

    @discardableResult
    public func runClaudeCodeOnce() -> UsageMonitorRunOutcome {
        guard usageProviderIsEnabled(.claudeCode) else {
            let outcome = UsageMonitorRunOutcome.skipped(tool: .claudeCode)
            writeStatus(for: outcome, heartbeatAt: now())
            return outcome
        }

        // 1. App-written mirror, fresh → consume the file (no API traffic).
        if let mtime = (try? fileManager.attributesOfItem(atPath: claudeUsageFilePath))?[.modificationDate] as? Date,
           now().timeIntervalSince(mtime) < claudeMirrorFreshness,
           let data = try? Data(contentsOf: URL(fileURLWithPath: claudeUsageFilePath)) {
            return acceptClaudePayload(data, receivedAt: mtime)
        }

        // 2. Mirror stale (app quit) → direct OAuth with file-only credentials.
        if let claudeOAuthFetcher {
            do {
                let payload = try claudeOAuthFetcher.fetchStatusLinePayload()
                return acceptClaudePayload(payload, receivedAt: now())
            } catch {
                let outcome = UsageMonitorRunOutcome.unavailable(reason: "Claude usage source unavailable")
                writeStatus(for: outcome, heartbeatAt: now())
                return outcome
            }
        }

        let outcome = UsageMonitorRunOutcome.unavailable(reason: "Claude usage source unavailable")
        writeStatus(for: outcome, heartbeatAt: now())
        return outcome
    }

    @discardableResult
    public func acceptClaudePayload(_ data: Data, receivedAt: Date? = nil) -> UsageMonitorRunOutcome {
        let acceptedAt = receivedAt ?? now()
        guard let parsed = ClaudeCodeRateLimitParser.parse(data: data, receivedAt: acceptedAt) else {
            let outcome = UsageMonitorRunOutcome.failed(reason: "Claude usage payload parse failed")
            writeStatus(for: outcome, heartbeatAt: acceptedAt)
            return outcome
        }
        return accept(parsed, acceptedAt: acceptedAt)
    }

    @discardableResult
    public func acceptCodexRateLimitResult(
        _ result: [String: AnyCodableLike],
        receivedAt: Date? = nil
    ) -> UsageMonitorRunOutcome {
        let acceptedAt = receivedAt ?? now()
        let message = CodexJSONRPCMessage(raw: ["result": .object(result)], kind: .response(id: .string("usage-monitor")))
        guard let parsed = CodexRateLimitParser.parse(message: message, receivedAt: acceptedAt) else {
            let outcome = UsageMonitorRunOutcome.failed(reason: "Codex usage payload parse failed")
            writeStatus(for: outcome, heartbeatAt: acceptedAt)
            return outcome
        }
        return accept(parsed, acceptedAt: acceptedAt)
    }

    private func accept(_ parsed: UsageSnapshot, acceptedAt: Date) -> UsageMonitorRunOutcome {
        guard usageProviderIsEnabled(parsed.tool) else {
            let outcome = UsageMonitorRunOutcome.skipped(tool: parsed.tool)
            writeStatus(for: outcome, heartbeatAt: acceptedAt)
            return outcome
        }

        let priorSnapshot = try? continuityStore.latestRecordedSnapshot(tool: parsed.tool)
        let priorSequence = try? continuityStore.latestAcceptedSampleSequence(tool: parsed.tool)
        let priorWeekly = priorSnapshot?.weeklySnapshotForForecast
        let sourceIsFresh = sampleIsFresh(receivedAt: acceptedAt)
        let today: TodayValue? = {
            guard sourceIsFresh else { return nil }
            guard case .available(let weekly) = parsed.weekly else { return nil }
            dailyAccumulator.recordTick(
                weekly: weekly,
                tool: parsed.tool,
                now: acceptedAt,
                calendar: calendar,
                timeZone: timeZone,
                priorWeekly: priorWeekly
            )
            return UsageForecastCalculator.forecast(
                weekly: weekly,
                baseline: dailyAccumulator.baseline(for: parsed.tool),
                priorWeekly: priorWeekly,
                now: acceptedAt,
                calendar: calendar,
                timeZone: timeZone
            )
        }()

        let snapshot = UsageSnapshot(
            tool: parsed.tool,
            planName: parsed.planName,
            fiveHour: parsed.fiveHour,
            weekly: parsed.weekly,
            today: today,
            availability: parsed.availability,
            lastRefresh: parsed.lastRefresh
        )
        let recordedSnapshot = sourceIsFresh
            ? snapshot
            : snapshot.markingStale(reason: Self.staleSampleReason)

        do {
            let seq = try continuityStore.recordAcceptedSnapshot(recordedSnapshot, acceptedAt: acceptedAt)
            if let seq {
                recordRecoveryEdges(
                    priorSnapshot: priorSnapshot,
                    currentSnapshot: recordedSnapshot,
                    priorSequence: priorSequence,
                    currentSequence: seq,
                    detectedAt: acceptedAt
                )
                recordThresholdCrossings(
                    priorSnapshot: priorSnapshot,
                    currentSnapshot: recordedSnapshot,
                    detectedAt: acceptedAt
                )
            }
            let outcome: UsageMonitorRunOutcome
            if !sourceIsFresh {
                outcome = .stale(tool: recordedSnapshot.tool)
            } else {
                outcome = seq == nil
                    ? .duplicate(tool: recordedSnapshot.tool)
                    : .accepted(tool: recordedSnapshot.tool)
            }
            writeStatus(for: outcome, heartbeatAt: acceptedAt)
            return outcome
        } catch {
            let outcome = UsageMonitorRunOutcome.failed(reason: "Continuity store write failed")
            writeStatus(for: outcome, heartbeatAt: acceptedAt)
            return outcome
        }
    }

    private func writeStatus(for outcome: UsageMonitorRunOutcome, heartbeatAt: Date) {
        let status: UsageMonitorStatus
        switch outcome {
        case .accepted(let tool):
            status = UsageMonitorStatus(
                state: .running,
                lastHeartbeatAt: heartbeatAt,
                lastAcceptedSampleAt: heartbeatAt,
                lastAcceptedTool: tool
            )
        case .duplicate(let tool):
            status = UsageMonitorStatus(
                state: .running,
                lastHeartbeatAt: heartbeatAt,
                lastAcceptedTool: tool
            )
        case .stale(let tool):
            status = UsageMonitorStatus(
                state: .running,
                lastHeartbeatAt: heartbeatAt,
                lastAcceptedTool: tool
            )
        case .skipped(let tool):
            status = UsageMonitorStatus(
                state: .running,
                lastHeartbeatAt: heartbeatAt,
                lastAcceptedTool: tool
            )
        case .unavailable(let reason):
            status = UsageMonitorStatus(state: .unavailable, lastHeartbeatAt: heartbeatAt, reason: reason)
        case .failed(let reason):
            status = UsageMonitorStatus(state: .failed, lastHeartbeatAt: heartbeatAt, reason: reason)
        }

        do {
            let url = URL(fileURLWithPath: statusPath)
            try BoughPrivateStorage.ensurePrivateDirectoryForFile(at: url, fileManager: fileManager)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(status).write(to: url, options: .atomic)
            try BoughPrivateStorage.protectPrivateFile(at: url, fileManager: fileManager)
        } catch {
            // Status writes are observability only; continuity store errors are
            // surfaced through the returned run outcome.
        }
    }

    private func writeCycleStatus(for outcomes: [UsageMonitorRunOutcome], heartbeatAt: Date) {
        if let accepted = outcomes.reversed().compactMap({ outcome -> UsageTool? in
            if case .accepted(let tool) = outcome { return tool }
            return nil
        }).first {
            writeStatus(for: .accepted(tool: accepted), heartbeatAt: heartbeatAt)
            return
        }

        if outcomes.contains(where: { outcome in
            if case .failed = outcome { return true }
            return false
        }) {
            writeStatus(for: .failed(reason: "Usage monitor cycle failed"), heartbeatAt: heartbeatAt)
            return
        }

        if outcomes.contains(where: { outcome in
            if case .unavailable = outcome { return true }
            return false
        }) {
            writeStatus(for: .unavailable(reason: "Usage sources unavailable"), heartbeatAt: heartbeatAt)
            return
        }

        if let nonFatal = outcomes.reversed().compactMap({ outcome -> UsageMonitorRunOutcome? in
            switch outcome {
            case .duplicate, .stale, .skipped:
                return outcome
            case .accepted, .unavailable, .failed:
                return nil
            }
        }).first {
            writeStatus(for: nonFatal, heartbeatAt: heartbeatAt)
            return
        }

        writeStatus(for: .unavailable(reason: "Usage sources unavailable"), heartbeatAt: heartbeatAt)
    }

    private func usageProviderIsEnabled(_ tool: UsageTool) -> Bool {
        guard fileManager.fileExists(atPath: commandPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: commandPath)) else {
            return true
        }
        let decoder = JSONDecoder()
        guard let command = try? decoder.decode(UsageMonitorCommand.self, from: data) else {
            return true
        }
        return command.isEnabled(tool)
    }

    private func sampleIsFresh(receivedAt: Date) -> Bool {
        Self.sampleTimestampIsFresh(receivedAt: receivedAt, now: now())
    }

    private func recordRecoveryEdges(
        priorSnapshot: UsageSnapshot?,
        currentSnapshot: UsageSnapshot,
        priorSequence: Int64?,
        currentSequence: Int64,
        detectedAt: Date
    ) {
        guard let priorSnapshot else { return }
        for windowKind in [UsageWindowKind.fiveHour, .weekly] {
            let currentWindow = currentSnapshot.windowSlot(for: windowKind)
            let resetIntervalID = currentWindow.acceptedSnapshot.map(UsageRecoveryPolicy.resetIntervalID(for:)) ?? ""
            let alreadyRecorded = (try? continuityStore.hasRecoveryEdge(
                tool: currentSnapshot.tool,
                windowKind: windowKind,
                resetIntervalID: resetIntervalID
            )) ?? false
            let existingCandidate = try? continuityStore.recoveryCandidate(
                tool: currentSnapshot.tool,
                windowKind: windowKind,
                resetIntervalID: resetIntervalID
            )
            let decision = UsageRecoveryPolicy.evaluate(UsageRecoveryPolicyInput(
                tool: currentSnapshot.tool,
                windowKind: windowKind,
                priorSlot: priorSnapshot.windowSlot(for: windowKind).acceptedForRecovery,
                currentSlot: currentWindow,
                priorAvailability: priorSnapshot.availability,
                currentAvailability: currentSnapshot.availability,
                priorAcceptedSequence: priorSequence,
                currentAcceptedSequence: currentSequence,
                resetProvenance: currentSnapshot.today?.basis.resetProvenance ?? .ordinaryProgress,
                existingCandidate: existingCandidate,
                edgeAlreadyRecorded: alreadyRecorded,
                detectedAt: detectedAt
            ))
            switch decision {
            case .candidate(let candidate):
                try? continuityStore.recordRecoveryCandidate(candidate)
            case .confirmed(let edge):
                try? continuityStore.recordRecoveryEdge(edge)
                try? continuityStore.clearRecoveryCandidate(
                    tool: edge.tool,
                    windowKind: edge.windowKind,
                    resetIntervalID: edge.resetIntervalID
                )
            case .none:
                break
            }
        }
    }

    private func recordThresholdCrossings(
        priorSnapshot: UsageSnapshot?,
        currentSnapshot: UsageSnapshot,
        detectedAt: Date
    ) {
        guard ((try? continuityStore.thresholdNotificationsMasterEnabled()) ?? false),
              ((try? continuityStore.thresholdNotificationPreference(tool: currentSnapshot.tool).isEnabled) ?? false) else {
            return
        }
        for crossing in UsageThresholdDetector.detectCrossings(
            previous: priorSnapshot,
            current: currentSnapshot,
            detectedAt: detectedAt
        ) {
            try? continuityStore.recordThresholdCrossing(
                tool: crossing.tool,
                windowKind: .weekly,
                thresholdPct: crossing.level.boundary,
                resetIntervalID: crossing.resetIntervalID,
                detectedAt: crossing.detectedAt
            )
        }
    }
}

private extension UsageWindowSlot {
    var acceptedForRecovery: UsageWindowSlot {
        acceptedSnapshot.map(UsageWindowSlot.available) ?? self
    }

    var acceptedSnapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .loading, .unavailable:
            return nil
        }
    }
}

private extension UsageSnapshot {
    func windowSlot(for kind: UsageWindowKind) -> UsageWindowSlot {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        }
    }

    var weeklySnapshotForForecast: UsageWindowSnapshot? {
        switch availability {
        case .available, .partial:
            if case .available(let snapshot) = weekly {
                return snapshot
            }
            return nil
        case .loading, .stale, .unavailable:
            return nil
        }
    }
}
