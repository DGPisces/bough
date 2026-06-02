import Foundation

@MainActor
protocol MusicPollingScheduling: AnyObject {
    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void)
    func stop()
}

final class TimerMusicPollingScheduler: MusicPollingScheduling {
    private var timer: Timer?
    private var currentInterval: TimeInterval?
    private var action: (@MainActor () -> Void)?

    func start(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.action = action
        guard currentInterval != interval || timer == nil else { return }

        timer?.invalidate()
        currentInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.action?()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentInterval = nil
        action = nil
    }
}

enum MusicPollingPolicy {
    static let activeInterval: TimeInterval = 1
    static let failureBackoffInterval: TimeInterval = 5
    static let playerUnavailableFallbackInterval: TimeInterval = 60
    static let failuresBeforeBackoff = 2

    static func shouldPoll(controlsEnabled: Bool, presentationNeeded: Bool) -> Bool {
        controlsEnabled && presentationNeeded
    }

    static func interval(consecutiveFailures: Int, playerAvailable: Bool = true) -> TimeInterval {
        guard playerAvailable else {
            return playerUnavailableFallbackInterval
        }
        return consecutiveFailures >= failuresBeforeBackoff ? failureBackoffInterval : activeInterval
    }
}
