import SwiftUI

func shouldTriggerJumpFailureFeedback(_ jumpChecks: [Bool]) -> Bool {
    !jumpChecks.contains(true)
}

/// Namespace for jump animation utilities shared between ApprovalBar and SessionCard
enum JumpAnimationHelper {
    static let shakeSequence = [8, -8, 6, -6, 3, -3, 0]
    static let shakeStepDuration: UInt64 = 35_000_000

    @MainActor
    static func runShake(offset: Binding<CGFloat>) async {
        for value in shakeSequence {
            withAnimation(.easeInOut(duration: 0.035)) {
                offset.wrappedValue = CGFloat(value)
            }
            try? await Task.sleep(nanoseconds: shakeStepDuration)
        }
    }
}

enum JumpValidationOutcome: Equatable {
    case success
    case failed
    case cancelled
}

func evaluateJumpValidation(
    delays: [UInt64],
    isCancelled: () -> Bool = { Task.isCancelled },
    sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
    checkSucceeded: () async -> Bool
) async -> JumpValidationOutcome {
    for delay in delays {
        await sleep(delay)
        if isCancelled() { return .cancelled }
        if await checkSucceeded() { return .success }
    }

    return isCancelled() ? .cancelled : .failed
}
