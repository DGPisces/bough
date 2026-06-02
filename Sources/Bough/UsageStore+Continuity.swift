import Foundation
import BoughCore

extension UsageStore {
    private var currentContinuityWriteMode: UsageContinuityWriteMode {
        fixedContinuityWriteMode ?? UsageContinuityWriteMode(defaults: defaults)
    }

    static func formattedYYYYMMDD(_ date: Date, timeZone: TimeZone) -> String {
        var localCal = Calendar.current
        localCal.timeZone = timeZone
        let c = localCal.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return "1970-01-01" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    func persistContinuitySnapshot(for tool: UsageTool) {
        guard usageStatisticsEnabled(tool: tool) else { return }
        guard currentContinuityWriteMode == .appOwned else { return }
        guard let continuityStore, let snapshot = snapshots[tool] else { return }
        let priorSnapshot = try? continuityStore.latestSnapshot(tool: tool)
        let priorSequence = try? continuityStore.latestAcceptedSampleSequence(tool: tool)
        let acceptedAt = snapshot.lastRefresh ?? now()
        guard let seq = try? continuityStore.recordAcceptedSnapshot(snapshot, acceptedAt: acceptedAt) else {
            return
        }
        recordRecoveryEdges(
            in: continuityStore,
            priorSnapshot: priorSnapshot,
            currentSnapshot: snapshot,
            priorSequence: priorSequence,
            currentSequence: seq,
            detectedAt: acceptedAt
        )
        recordThresholdCrossings(
            in: continuityStore,
            priorSnapshot: priorSnapshot,
            currentSnapshot: snapshot,
            detectedAt: acceptedAt,
            deliverImmediately: true
        )
    }

    private func recordThresholdCrossings(
        in continuityStore: UsageContinuityStore,
        priorSnapshot: UsageSnapshot?,
        currentSnapshot: UsageSnapshot,
        detectedAt: Date,
        deliverImmediately: Bool
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
            guard deliverImmediately else { continue }
            Task {
                _ = await UsageNotificationService(
                    copy: .localized(),
                    thresholdCopy: .localized()
                ).sendThresholdNotificationIfAllowed(
                    tool: crossing.tool,
                    threshold: crossing.level,
                    resetIntervalID: crossing.resetIntervalID,
                    continuityStore: continuityStore
                )
            }
        }
    }

    private func recordRecoveryEdges(
        in continuityStore: UsageContinuityStore,
        priorSnapshot: UsageSnapshot?,
        currentSnapshot: UsageSnapshot,
        priorSequence: Int64?,
        currentSequence: Int64,
        detectedAt: Date
    ) {
        guard let priorSnapshot else { return }
        for windowKind in [UsageWindowKind.fiveHour, .weekly] {
            let currentWindow = currentSnapshot.windowSlot(for: windowKind)
            let resetIntervalID = currentWindow.availableSnapshot.map(UsageRecoveryPolicy.resetIntervalID(for:)) ?? ""
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
                priorAvailability: .available,
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
                if ((try? continuityStore.recoveryReminderPreference(tool: edge.tool, windowKind: edge.windowKind).isEnabled) ?? false) {
                    Task {
                        _ = await UsageNotificationService(copy: .localized()).sendNotificationIfAllowed(
                            for: edge,
                            continuityStore: continuityStore
                        )
                    }
                }
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
}
