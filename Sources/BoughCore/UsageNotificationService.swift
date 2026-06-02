import Foundation
@preconcurrency import UserNotifications

public enum UsageNotificationPermissionState: Equatable, Sendable {
    case authorized
    case provisional
    case ephemeral
    case notDetermined
    case denied
    case unavailable
    case failed(String)

    public var canSendNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unavailable, .failed:
            return false
        }
    }
}

public struct UsageNotificationCreateResult: Equatable, Sendable {
    public let permissionState: UsageNotificationPermissionState
    public let notificationIdentifier: String?
    public let errorMessage: String?
}

public protocol UsageNotificationCenterClient: Sendable {
    func permissionState() async -> UsageNotificationPermissionState
    func requestAuthorization() async -> UsageNotificationPermissionState
    func sendNotification(identifier: String, title: String, body: String) async throws
}

public struct SystemUsageNotificationCenterClient: UsageNotificationCenterClient, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func permissionState() async -> UsageNotificationPermissionState {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.permissionState(from: settings.authorizationStatus))
            }
        }
    }

    public func requestAuthorization() async -> UsageNotificationPermissionState {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if granted {
                return await permissionState()
            }
            return .denied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func sendNotification(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    private static func permissionState(from status: UNAuthorizationStatus) -> UsageNotificationPermissionState {
        switch status {
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .unavailable
        }
    }
}

/// Localized title/body templates for the recovery notification surface.
/// The default `.englishFallback` matches the pre-Phase-28 hardcoded strings
/// so `BoughCore` tests retain their existing assertions without taking a
/// `L10n` dependency. The Bough executable target injects a localized
/// instance built from `L10n.shared`.
public struct UsageNotificationCopy: Sendable {
    public let titleFiveHour: String
    public let titleWeekly: String
    public let defaultBody: String
    public let detailedBody: String
    public let codexName: String
    public let claudeCodeName: String

    public init(
        titleFiveHour: String,
        titleWeekly: String,
        defaultBody: String,
        detailedBody: String,
        codexName: String,
        claudeCodeName: String
    ) {
        self.titleFiveHour = titleFiveHour
        self.titleWeekly = titleWeekly
        self.defaultBody = defaultBody
        self.detailedBody = detailedBody
        self.codexName = codexName
        self.claudeCodeName = claudeCodeName
    }

    public static let englishFallback = UsageNotificationCopy(
        titleFiveHour: "%@ 5h quota recovered",
        titleWeekly: "%@ weekly quota recovered",
        defaultBody: "Bough saw this quota window recover.",
        detailedBody: "Bough saw accepted quota recover from %@%% used to %@%% used.",
        codexName: "Codex",
        claudeCodeName: "Claude Code"
    )
}

public struct UsageThresholdNotificationCopy: Sendable {
    public let title20: String
    public let title5: String
    public let title0: String
    public let body: String
    public let codexName: String
    public let claudeCodeName: String

    public init(
        title20: String,
        title5: String,
        title0: String,
        body: String,
        codexName: String,
        claudeCodeName: String
    ) {
        self.title20 = title20
        self.title5 = title5
        self.title0 = title0
        self.body = body
        self.codexName = codexName
        self.claudeCodeName = claudeCodeName
    }

    public static let englishFallback = UsageThresholdNotificationCopy(
        title20: "%@ weekly quota at 20%% remaining",
        title5: "%@ weekly quota at 5%% remaining",
        title0: "%@ weekly quota exhausted",
        body: "Bough saw your %@ weekly quota cross %@%% remaining.",
        codexName: "Codex",
        claudeCodeName: "Claude Code"
    )
}

public struct UsageNotificationService: Sendable {
    private let client: any UsageNotificationCenterClient
    private let now: @Sendable () -> Date
    private let copy: UsageNotificationCopy
    private let thresholdCopy: UsageThresholdNotificationCopy
    private let providerEnabled: @Sendable (UsageTool) -> Bool

    public init(
        client: any UsageNotificationCenterClient = SystemUsageNotificationCenterClient(),
        copy: UsageNotificationCopy = .englishFallback,
        thresholdCopy: UsageThresholdNotificationCopy = .englishFallback,
        now: @escaping @Sendable () -> Date = { Date() },
        providerEnabled: @escaping @Sendable (UsageTool) -> Bool = { _ in true }
    ) {
        self.client = client
        self.copy = copy
        self.thresholdCopy = thresholdCopy
        self.now = now
        self.providerEnabled = providerEnabled
    }

    public func permissionState() async -> UsageNotificationPermissionState {
        await client.permissionState()
    }

    public func requestAccessForExplicitUserAction() async -> UsageNotificationPermissionState {
        await client.requestAuthorization()
    }

    @discardableResult
    public func sendNotificationIfAllowed(
        for edge: UsageRecoveryEdge,
        continuityStore: UsageContinuityStore
    ) async -> UsageNotificationCreateResult {
        await sendNotificationIfAllowed(
            tool: edge.tool,
            windowKind: edge.windowKind,
            resetIntervalID: edge.resetIntervalID,
            title: title(tool: edge.tool, windowKind: edge.windowKind),
            body: detailedBody(for: edge),
            continuityStore: continuityStore
        )
    }

    @discardableResult
    public func sendNotificationIfAllowed(
        for record: UsageRecoveryEdgeRecord,
        continuityStore: UsageContinuityStore
    ) async -> UsageNotificationCreateResult {
        await sendNotificationIfAllowed(
            tool: record.tool,
            windowKind: record.windowKind,
            resetIntervalID: record.resetIntervalID,
            title: title(tool: record.tool, windowKind: record.windowKind),
            body: copy.defaultBody,
            continuityStore: continuityStore
        )
    }

    public func sendPendingNotifications(from continuityStore: UsageContinuityStore) async {
        guard let records = try? continuityStore.recoveryEdgeRecords() else { return }
        for record in records where record.firedAt == nil {
            guard providerEnabled(record.tool) else { continue }
            guard let preference = try? continuityStore.recoveryReminderPreference(
                tool: record.tool,
                windowKind: record.windowKind
            ), preference.isEnabled else {
                continue
            }
            _ = await sendNotificationIfAllowed(for: record, continuityStore: continuityStore)
        }
    }

    @discardableResult
    public func sendThresholdNotificationIfAllowed(
        tool: UsageTool,
        threshold: UsageThresholdLevel,
        resetIntervalID: String,
        continuityStore: UsageContinuityStore
    ) async -> UsageNotificationCreateResult {
        guard providerEnabled(tool) else {
            return UsageNotificationCreateResult(
                permissionState: .unavailable,
                notificationIdentifier: nil,
                errorMessage: "provider_disabled"
            )
        }
        guard let preference = try? continuityStore.thresholdNotificationPreference(tool: tool),
              preference.isEnabled else {
            return UsageNotificationCreateResult(
                permissionState: .unavailable,
                notificationIdentifier: nil,
                errorMessage: "preference_disabled"
            )
        }

        return await sendThresholdNotification(
            tool: tool,
            thresholdPct: threshold.boundary,
            resetIntervalID: resetIntervalID,
            continuityStore: continuityStore
        )
    }

    public func sendPendingThresholdNotifications(from continuityStore: UsageContinuityStore) async {
        guard let records = try? continuityStore.pendingThresholdNotificationRecords() else { return }
        guard ((try? continuityStore.thresholdNotificationsMasterEnabled()) ?? false) else { return }
        for record in records {
            guard providerEnabled(record.tool) else {
                try? continuityStore.markThresholdNotificationFailed(
                    tool: record.tool,
                    windowKind: record.windowKind,
                    thresholdPct: record.thresholdPct,
                    resetIntervalID: record.resetIntervalID,
                    lastError: "provider_disabled"
                )
                continue
            }
            guard record.windowKind == .weekly else {
                try? continuityStore.markThresholdNotificationFailed(
                    tool: record.tool,
                    windowKind: record.windowKind,
                    thresholdPct: record.thresholdPct,
                    resetIntervalID: record.resetIntervalID,
                    lastError: "unsupported_window"
                )
                continue
            }
            guard let currentSnapshot = try? continuityStore.latestSnapshot(tool: record.tool),
                  let currentWeekly = currentSnapshot.weekly.availableSnapshot,
                  UsageRecoveryPolicy.resetIntervalID(for: currentWeekly) == record.resetIntervalID else {
                try? continuityStore.markThresholdNotificationFailed(
                    tool: record.tool,
                    windowKind: record.windowKind,
                    thresholdPct: record.thresholdPct,
                    resetIntervalID: record.resetIntervalID,
                    lastError: "stale_interval"
                )
                continue
            }
            guard let preference = try? continuityStore.thresholdNotificationPreference(tool: record.tool),
                  preference.isEnabled else {
                try? continuityStore.markThresholdNotificationFailed(
                    tool: record.tool,
                    windowKind: record.windowKind,
                    thresholdPct: record.thresholdPct,
                    resetIntervalID: record.resetIntervalID,
                    lastError: "preference_disabled"
                )
                continue
            }
            _ = await sendThresholdNotification(
                tool: record.tool,
                thresholdPct: record.thresholdPct,
                resetIntervalID: record.resetIntervalID,
                continuityStore: continuityStore
            )
        }
    }

    private func sendNotificationIfAllowed(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        resetIntervalID: String,
        title: String,
        body: String,
        continuityStore: UsageContinuityStore
    ) async -> UsageNotificationCreateResult {
        guard providerEnabled(tool) else {
            return UsageNotificationCreateResult(
                permissionState: .unavailable,
                notificationIdentifier: nil,
                errorMessage: "provider_disabled"
            )
        }
        let state = await client.permissionState()
        guard state.canSendNotifications else {
            try? continuityStore.markRecoveryReminderFailed(
                tool: tool,
                windowKind: windowKind,
                resetIntervalID: resetIntervalID,
                errorMessage: "Notifications permission is not available: \(state.userVisibleName)"
            )
            return UsageNotificationCreateResult(
                permissionState: state,
                notificationIdentifier: nil,
                errorMessage: state.userVisibleName
            )
        }

        let identifier = notificationIdentifier(tool: tool, windowKind: windowKind, resetIntervalID: resetIntervalID)
        do {
            try await client.sendNotification(identifier: identifier, title: title, body: body)
            try continuityStore.markRecoveryReminderCreated(
                tool: tool,
                windowKind: windowKind,
                resetIntervalID: resetIntervalID,
                reminderIdentifier: identifier,
                firedAt: now()
            )
            return UsageNotificationCreateResult(
                permissionState: state,
                notificationIdentifier: identifier,
                errorMessage: nil
            )
        } catch {
            try? continuityStore.markRecoveryReminderFailed(
                tool: tool,
                windowKind: windowKind,
                resetIntervalID: resetIntervalID,
                errorMessage: error.localizedDescription
            )
            return UsageNotificationCreateResult(
                permissionState: .failed(error.localizedDescription),
                notificationIdentifier: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func sendThresholdNotification(
        tool: UsageTool,
        thresholdPct: Double,
        resetIntervalID: String,
        continuityStore: UsageContinuityStore
    ) async -> UsageNotificationCreateResult {
        guard ((try? continuityStore.thresholdNotificationsMasterEnabled()) ?? false) else {
            return UsageNotificationCreateResult(
                permissionState: .unavailable,
                notificationIdentifier: nil,
                errorMessage: "master_disabled"
            )
        }

        let state = await client.permissionState()
        guard state.canSendNotifications else {
            try? continuityStore.markThresholdNotificationFailed(
                tool: tool,
                windowKind: .weekly,
                thresholdPct: thresholdPct,
                resetIntervalID: resetIntervalID,
                lastError: "permission_denied"
            )
            return UsageNotificationCreateResult(
                permissionState: state,
                notificationIdentifier: nil,
                errorMessage: state.userVisibleName
            )
        }

        let identifier = thresholdNotificationIdentifier(
            tool: tool,
            thresholdPct: thresholdPct,
            resetIntervalID: resetIntervalID
        )
        do {
            try await client.sendNotification(
                identifier: identifier,
                title: thresholdTitle(tool: tool, thresholdPct: thresholdPct),
                body: thresholdBody(tool: tool, thresholdPct: thresholdPct)
            )
            try continuityStore.markThresholdNotificationCreated(
                tool: tool,
                windowKind: .weekly,
                thresholdPct: thresholdPct,
                resetIntervalID: resetIntervalID,
                reminderIdentifier: identifier,
                firedAt: now()
            )
            return UsageNotificationCreateResult(
                permissionState: state,
                notificationIdentifier: identifier,
                errorMessage: nil
            )
        } catch {
            try? continuityStore.markThresholdNotificationFailed(
                tool: tool,
                windowKind: .weekly,
                thresholdPct: thresholdPct,
                resetIntervalID: resetIntervalID,
                lastError: error.localizedDescription
            )
            return UsageNotificationCreateResult(
                permissionState: .failed(error.localizedDescription),
                notificationIdentifier: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func notificationIdentifier(tool: UsageTool, windowKind: UsageWindowKind, resetIntervalID: String) -> String {
        "bough.usage-recovery.\(tool.rawValue).\(windowKind.rawValue).\(resetIntervalID)"
    }

    private func thresholdNotificationIdentifier(
        tool: UsageTool,
        thresholdPct: Double,
        resetIntervalID: String
    ) -> String {
        "bough.usage-threshold.\(tool.rawValue).weekly.\(Int(thresholdPct.rounded())).\(resetIntervalID)"
    }

    private func title(tool: UsageTool, windowKind: UsageWindowKind) -> String {
        let template: String
        switch windowKind {
        case .fiveHour: template = copy.titleFiveHour
        case .weekly:   template = copy.titleWeekly
        }
        let name: String
        switch tool {
        case .codex:      name = copy.codexName
        case .claudeCode: name = copy.claudeCodeName
        }
        return String(format: template, name)
    }

    private func detailedBody(for edge: UsageRecoveryEdge) -> String {
        String(
            format: copy.detailedBody,
            "\(Int(edge.priorUsedPercent.rounded()))",
            "\(Int(edge.currentUsedPercent.rounded()))"
        )
    }

    private func thresholdTitle(tool: UsageTool, thresholdPct: Double) -> String {
        let template: String
        switch Int(thresholdPct.rounded()) {
        case 20: template = thresholdCopy.title20
        case 5: template = thresholdCopy.title5
        default: template = thresholdCopy.title0
        }
        return String(format: template, toolName(tool, copy: thresholdCopy))
    }

    private func thresholdBody(tool: UsageTool, thresholdPct: Double) -> String {
        String(format: thresholdCopy.body, toolName(tool, copy: thresholdCopy), "\(Int(thresholdPct.rounded()))")
    }

    private func toolName(_ tool: UsageTool, copy: UsageThresholdNotificationCopy) -> String {
        switch tool {
        case .codex: return copy.codexName
        case .claudeCode: return copy.claudeCodeName
        }
    }
}

private extension UsageWindowSlot {
    var availableSnapshot: UsageWindowSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _):
            return snapshot
        case .loading, .unavailable:
            return nil
        }
    }
}

private extension UsageNotificationPermissionState {
    var userVisibleName: String {
        switch self {
        case .authorized: return "Authorized"
        case .provisional: return "Provisionally authorized"
        case .ephemeral: return "Ephemerally authorized"
        case .notDetermined: return "Permission not determined"
        case .denied: return "Permission denied"
        case .unavailable: return "Notifications unavailable"
        case .failed(let message): return message
        }
    }
}

private extension UsageTool {
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }
}

private extension UsageWindowKind {
    var displayName: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "weekly"
        }
    }
}
