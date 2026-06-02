import Foundation

public enum UsageContinuityWriterOwner: String, Codable, Equatable, Sendable {
    case app
    case helper
}

public enum UsageMonitorCollectionState: String, Codable, Equatable, Sendable {
    case running
    case stale
    case failed
    case unavailable
}

public enum UsageMonitorRunOutcome: Equatable, Sendable {
    case accepted(tool: UsageTool)
    case duplicate(tool: UsageTool)
    case stale(tool: UsageTool)
    case skipped(tool: UsageTool)
    case unavailable(reason: String)
    case failed(reason: String)
}

public struct UsageMonitorCommand: Codable, Equatable, Sendable {
    public let enabledTools: [UsageTool]

    public init(enabledTools: [UsageTool]) {
        self.enabledTools = UsageTool.selectableQuotaProviders.filter { enabledTools.contains($0) }
    }

    public func isEnabled(_ tool: UsageTool) -> Bool {
        enabledTools.contains(tool)
    }
}

public struct UsageMonitorStatus: Codable, Equatable, Sendable {
    public let state: UsageMonitorCollectionState
    public let writerOwner: UsageContinuityWriterOwner
    public let lastHeartbeatAt: Date
    public let lastAcceptedSampleAt: Date?
    public let lastAcceptedTool: UsageTool?
    public let reason: String?

    public init(
        state: UsageMonitorCollectionState,
        writerOwner: UsageContinuityWriterOwner = .helper,
        lastHeartbeatAt: Date,
        lastAcceptedSampleAt: Date? = nil,
        lastAcceptedTool: UsageTool? = nil,
        reason: String? = nil
    ) {
        self.state = state
        self.writerOwner = writerOwner
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastAcceptedSampleAt = lastAcceptedSampleAt
        self.lastAcceptedTool = lastAcceptedTool
        self.reason = reason
    }
}
