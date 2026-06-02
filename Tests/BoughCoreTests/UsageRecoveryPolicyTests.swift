import XCTest
@testable import BoughCore

final class UsageRecoveryPolicyTests: XCTestCase {
    func testConfirmsFiveHourRecoveryWithResetEvidence() {
        let prior = window(.fiveHour, used: 100, reset: 1_000)
        let current = window(.fiveHour, used: 20, reset: 2_000)

        let decision = UsageRecoveryPolicy.evaluate(input(
            windowKind: .fiveHour,
            prior: .available(prior),
            current: .available(current),
            priorSequence: 10,
            currentSequence: 11,
            provenance: .explicitReset
        ))

        guard case .confirmed(let edge) = decision else {
            return XCTFail("expected confirmed edge, got \(decision)")
        }
        XCTAssertEqual(edge.tool, .codex)
        XCTAssertEqual(edge.windowKind, .fiveHour)
        XCTAssertEqual(edge.priorUsedPercent, 100)
        XCTAssertEqual(edge.currentUsedPercent, 20)
        XCTAssertEqual(edge.resetIntervalID, UsageRecoveryPolicy.resetIntervalID(for: current))
    }

    func testConfirmsWeeklyRecoveryWithResetWindowChange() {
        let prior = window(.weekly, used: 100, reset: 1_000)
        let current = window(.weekly, used: 10, reset: 10_000)

        let decision = UsageRecoveryPolicy.evaluate(input(
            windowKind: .weekly,
            prior: .available(prior),
            current: .available(current),
            priorSequence: 1,
            currentSequence: 2,
            provenance: .ordinaryProgress
        ))

        guard case .confirmed(let edge) = decision else {
            return XCTFail("expected confirmed edge, got \(decision)")
        }
        XCTAssertEqual(edge.windowKind, .weekly)
    }

    func testSuppressesStaleFailedUnavailableAndPartialSamples() {
        let prior = window(.weekly, used: 100, reset: 1_000)
        let current = window(.weekly, used: 10, reset: 10_000)

        let decisions = [
            UsageRecoveryPolicy.evaluate(input(
                windowKind: .weekly,
                prior: .stale(prior, reason: "stale"),
                current: .available(current),
                priorSequence: 1,
                currentSequence: 2,
                provenance: .explicitReset
            )),
            UsageRecoveryPolicy.evaluate(input(
                windowKind: .weekly,
                prior: .available(prior),
                current: .stale(current, reason: "stale"),
                priorSequence: 1,
                currentSequence: 2,
                provenance: .explicitReset
            )),
            UsageRecoveryPolicy.evaluate(input(
                windowKind: .weekly,
                prior: .available(prior),
                current: .available(current),
                priorAvailability: .partial(reason: "missing"),
                priorSequence: 1,
                currentSequence: 2,
                provenance: .explicitReset
            )),
            UsageRecoveryPolicy.evaluate(input(
                windowKind: .weekly,
                prior: .available(prior),
                current: .available(current),
                currentAvailability: .stale(reason: "failed"),
                priorSequence: 1,
                currentSequence: 2,
                provenance: .explicitReset
            ))
        ]

        for decision in decisions {
            guard case .none = decision else {
                return XCTFail("expected suppression, got \(decision)")
            }
        }
    }

    func testSuppressesOlderEqualDuplicateProviderAndSmallCorrectionSamples() {
        let prior = window(.weekly, used: 100, reset: 1_000)
        let current = window(.weekly, used: 99, reset: 10_000)

        let older = UsageRecoveryPolicy.evaluate(input(
            windowKind: .weekly,
            prior: .available(prior),
            current: .available(window(.weekly, used: 10, reset: 10_000)),
            priorSequence: 2,
            currentSequence: 2,
            provenance: .explicitReset
        ))
        let duplicate = UsageRecoveryPolicy.evaluate(input(
            windowKind: .weekly,
            prior: .available(prior),
            current: .available(window(.weekly, used: 10, reset: 10_000)),
            priorSequence: 1,
            currentSequence: 2,
            provenance: .explicitReset,
            edgeAlreadyRecorded: true
        ))
        let providerSwitch = UsageRecoveryPolicy.evaluate(input(
            tool: .claudeCode,
            windowKind: .fiveHour,
            prior: .available(prior),
            current: .available(window(.fiveHour, used: 10, reset: 10_000)),
            priorSequence: 1,
            currentSequence: 2,
            provenance: .explicitReset
        ))
        let smallCorrection = UsageRecoveryPolicy.evaluate(input(
            windowKind: .weekly,
            prior: .available(prior),
            current: .available(current),
            priorSequence: 1,
            currentSequence: 2,
            provenance: .explicitReset
        ))

        for decision in [older, duplicate, providerSwitch, smallCorrection] {
            guard case .none = decision else {
                return XCTFail("expected suppression, got \(decision)")
            }
        }
    }

    func testTwoSampleConfirmationForNoResetEvidence() {
        let prior = window(.fiveHour, used: 100, reset: 5_000)
        let current = window(.fiveHour, used: 60, reset: 5_000)

        let first = UsageRecoveryPolicy.evaluate(input(
            windowKind: .fiveHour,
            prior: .available(prior),
            current: .available(current),
            priorSequence: 1,
            currentSequence: 2,
            provenance: .ordinaryProgress
        ))

        guard case .candidate(let candidate) = first else {
            return XCTFail("expected candidate, got \(first)")
        }

        let second = UsageRecoveryPolicy.evaluate(input(
            windowKind: .fiveHour,
            prior: .available(current),
            current: .available(window(.fiveHour, used: 55, reset: 5_000)),
            priorSequence: 2,
            currentSequence: 3,
            provenance: .ordinaryProgress,
            existingCandidate: candidate
        ))

        guard case .confirmed(let edge) = second else {
            return XCTFail("expected confirmed edge, got \(second)")
        }
        XCTAssertEqual(edge.resetIntervalID, candidate.resetIntervalID)
        XCTAssertEqual(edge.priorUsedPercent, 100)
        XCTAssertEqual(edge.currentUsedPercent, 55)
    }

    private func input(
        tool: UsageTool = .codex,
        windowKind: UsageWindowKind,
        prior: UsageWindowSlot,
        current: UsageWindowSlot,
        priorAvailability: UsageAvailability = .available,
        currentAvailability: UsageAvailability = .available,
        priorSequence: Int64?,
        currentSequence: Int64,
        provenance: UsageResetProvenance,
        existingCandidate: UsageRecoveryCandidate? = nil,
        edgeAlreadyRecorded: Bool = false
    ) -> UsageRecoveryPolicyInput {
        UsageRecoveryPolicyInput(
            tool: tool,
            windowKind: windowKind,
            priorSlot: prior,
            currentSlot: current,
            priorAvailability: priorAvailability,
            currentAvailability: currentAvailability,
            priorAcceptedSequence: priorSequence,
            currentAcceptedSequence: currentSequence,
            resetProvenance: provenance,
            existingCandidate: existingCandidate,
            edgeAlreadyRecorded: edgeAlreadyRecorded,
            detectedAt: Date(timeIntervalSince1970: 20_000)
        )
    }

    private func window(_ kind: UsageWindowKind, used: Double, reset: TimeInterval) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            kind: kind,
            usedPercent: used,
            resetsAt: Date(timeIntervalSince1970: reset),
            windowDurationMins: kind == .fiveHour ? 300 : 10_080,
            sourceLabel: "Codex",
            updatedAt: Date(timeIntervalSince1970: reset - 100)
        )
    }
}
