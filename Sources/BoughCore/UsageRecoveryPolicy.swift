import Foundation

public struct UsageRecoveryCandidate: Equatable, Sendable {
    public let tool: UsageTool
    public let windowKind: UsageWindowKind
    public let resetIntervalID: String
    public let acceptedSequence: Int64
    public let priorUsedPercent: Double
    public let currentUsedPercent: Double
    public let detectedAt: Date

    public init(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        resetIntervalID: String,
        acceptedSequence: Int64,
        priorUsedPercent: Double = 0,
        currentUsedPercent: Double = 0,
        detectedAt: Date
    ) {
        self.tool = tool
        self.windowKind = windowKind
        self.resetIntervalID = resetIntervalID
        self.acceptedSequence = acceptedSequence
        self.priorUsedPercent = priorUsedPercent
        self.currentUsedPercent = currentUsedPercent
        self.detectedAt = detectedAt
    }
}

public struct UsageRecoveryEdge: Equatable, Sendable {
    public let tool: UsageTool
    public let windowKind: UsageWindowKind
    public let resetIntervalID: String
    public let acceptedSequence: Int64
    public let priorUsedPercent: Double
    public let currentUsedPercent: Double
    public let resetProvenance: UsageResetProvenance
    public let detectedAt: Date

    public init(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        resetIntervalID: String,
        acceptedSequence: Int64,
        priorUsedPercent: Double,
        currentUsedPercent: Double,
        resetProvenance: UsageResetProvenance,
        detectedAt: Date
    ) {
        self.tool = tool
        self.windowKind = windowKind
        self.resetIntervalID = resetIntervalID
        self.acceptedSequence = acceptedSequence
        self.priorUsedPercent = priorUsedPercent
        self.currentUsedPercent = currentUsedPercent
        self.resetProvenance = resetProvenance
        self.detectedAt = detectedAt
    }
}

public enum UsageRecoveryPolicyDecision: Equatable, Sendable {
    case none(reason: String)
    case candidate(UsageRecoveryCandidate)
    case confirmed(UsageRecoveryEdge)
}

public struct UsageRecoveryPolicyInput: Equatable, Sendable {
    public let tool: UsageTool
    public let windowKind: UsageWindowKind
    public let priorSlot: UsageWindowSlot
    public let currentSlot: UsageWindowSlot
    public let priorAvailability: UsageAvailability
    public let currentAvailability: UsageAvailability
    public let priorAcceptedSequence: Int64?
    public let currentAcceptedSequence: Int64
    public let resetProvenance: UsageResetProvenance
    public let existingCandidate: UsageRecoveryCandidate?
    public let edgeAlreadyRecorded: Bool
    public let detectedAt: Date

    public init(
        tool: UsageTool,
        windowKind: UsageWindowKind,
        priorSlot: UsageWindowSlot,
        currentSlot: UsageWindowSlot,
        priorAvailability: UsageAvailability,
        currentAvailability: UsageAvailability,
        priorAcceptedSequence: Int64?,
        currentAcceptedSequence: Int64,
        resetProvenance: UsageResetProvenance,
        existingCandidate: UsageRecoveryCandidate? = nil,
        edgeAlreadyRecorded: Bool = false,
        detectedAt: Date
    ) {
        self.tool = tool
        self.windowKind = windowKind
        self.priorSlot = priorSlot
        self.currentSlot = currentSlot
        self.priorAvailability = priorAvailability
        self.currentAvailability = currentAvailability
        self.priorAcceptedSequence = priorAcceptedSequence
        self.currentAcceptedSequence = currentAcceptedSequence
        self.resetProvenance = resetProvenance
        self.existingCandidate = existingCandidate
        self.edgeAlreadyRecorded = edgeAlreadyRecorded
        self.detectedAt = detectedAt
    }
}

public enum UsageRecoveryPolicy {
    public static let exhaustedThreshold: Double = 99.5
    public static let usableThreshold: Double = 99.5
    public static let correctionTolerancePercent: Double = 2.0

    public static func evaluate(_ input: UsageRecoveryPolicyInput) -> UsageRecoveryPolicyDecision {
        guard !input.edgeAlreadyRecorded else {
            return .none(reason: "edge already recorded")
        }
        guard let priorSequence = input.priorAcceptedSequence,
              input.currentAcceptedSequence > priorSequence else {
            return .none(reason: "older or equal sample")
        }
        guard input.priorAvailability.isAcceptedForRecovery,
              input.currentAvailability.isAcceptedForRecovery else {
            return .none(reason: "non-accepted availability")
        }
        guard case .available(let current) = input.currentSlot else {
            return .none(reason: "non-available current window")
        }
        guard current.kind == input.windowKind else {
            return .none(reason: "window mismatch")
        }
        guard current.usedPercent < usableThreshold else {
            return .none(reason: "current window is still exhausted")
        }

        let resetIntervalID = Self.resetIntervalID(for: current)
        if let candidate = input.existingCandidate {
            guard candidate.tool == input.tool,
                  candidate.windowKind == input.windowKind,
                  candidate.resetIntervalID == resetIntervalID,
                  input.currentAcceptedSequence > candidate.acceptedSequence else {
                return .none(reason: "candidate mismatch")
            }
            return .confirmed(UsageRecoveryEdge(
                tool: input.tool,
                windowKind: input.windowKind,
                resetIntervalID: resetIntervalID,
                acceptedSequence: input.currentAcceptedSequence,
                priorUsedPercent: candidate.priorUsedPercent,
                currentUsedPercent: current.usedPercent,
                resetProvenance: input.resetProvenance,
                detectedAt: input.detectedAt
            ))
        }

        guard case .available(let prior) = input.priorSlot else {
            return .none(reason: "non-available prior window")
        }
        guard prior.kind == input.windowKind else {
            return .none(reason: "window mismatch")
        }
        guard prior.usedPercent >= exhaustedThreshold else {
            return .none(reason: "prior window was not exhausted")
        }

        let drop = prior.usedPercent - current.usedPercent
        guard drop > correctionTolerancePercent else {
            return .none(reason: "small correction")
        }

        if hasResetEvidence(prior: prior, current: current, provenance: input.resetProvenance) {
            return .confirmed(edge(
                input: input,
                prior: prior,
                current: current,
                resetIntervalID: resetIntervalID,
                provenance: input.resetProvenance
            ))
        }

        return .candidate(UsageRecoveryCandidate(
            tool: input.tool,
            windowKind: input.windowKind,
            resetIntervalID: resetIntervalID,
            acceptedSequence: input.currentAcceptedSequence,
            priorUsedPercent: prior.usedPercent,
            currentUsedPercent: current.usedPercent,
            detectedAt: input.detectedAt
        ))
    }

    public static func resetIntervalID(for window: UsageWindowSnapshot) -> String {
        let reset = Int(window.resetsAt.timeIntervalSince1970.rounded())
        return "\(window.kind.rawValue):\(window.windowDurationMins):\(reset)"
    }

    private static func hasResetEvidence(
        prior: UsageWindowSnapshot,
        current: UsageWindowSnapshot,
        provenance: UsageResetProvenance
    ) -> Bool {
        switch provenance {
        case .explicitReset, .implicitReset:
            return true
        case .ordinaryProgress, .correctionIgnored:
            return current.resetsAt > prior.resetsAt
        }
    }

    private static func edge(
        input: UsageRecoveryPolicyInput,
        prior: UsageWindowSnapshot,
        current: UsageWindowSnapshot,
        resetIntervalID: String,
        provenance: UsageResetProvenance
    ) -> UsageRecoveryEdge {
        UsageRecoveryEdge(
            tool: input.tool,
            windowKind: input.windowKind,
            resetIntervalID: resetIntervalID,
            acceptedSequence: input.currentAcceptedSequence,
            priorUsedPercent: prior.usedPercent,
            currentUsedPercent: current.usedPercent,
            resetProvenance: provenance,
            detectedAt: input.detectedAt
        )
    }
}

private extension UsageAvailability {
    var isAcceptedForRecovery: Bool {
        switch self {
        case .available:
            return true
        case .loading, .partial, .stale, .unavailable:
            return false
        }
    }
}
