import Foundation
import Observation

@MainActor
@Observable
final class MusicNowPlayingStore {
    static let didChangeNotification = Notification.Name("MusicNowPlayingStore.didChangeNotification")

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let service: MusicNowPlayingServicing

    @ObservationIgnored
    private let scheduler: MusicPollingScheduling

    @ObservationIgnored
    private let now: () -> Date

    @ObservationIgnored
    private var presentationNeeded = false

    @ObservationIgnored
    private var consecutiveFailures = 0

    @ObservationIgnored
    private var inFlightRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var postCommandRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var activePollingInterval: TimeInterval?

    @ObservationIgnored
    private(set) var publishRevision = 0

    private(set) var state: MusicServiceState = .disabled
    private(set) var softFailure: MusicSoftFailure?

    var snapshot: MusicNowPlayingSnapshot? {
        state.snapshot
    }

    var settingsAbnormalMessage: String? {
        if let softFailure {
            return softFailure.message
        }
        return state.abnormalMessage
    }

    init(
        defaults: UserDefaults = .standard,
        service: MusicNowPlayingServicing = NoopMusicNowPlayingService(),
        scheduler: MusicPollingScheduling? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.service = service
        self.scheduler = scheduler ?? TimerMusicPollingScheduler()
        self.now = now
        self.service.setPollingAvailabilityDidChangeHandler { [weak self] in
            self?.handlePollingAvailabilityChanged()
        }
    }

    func setPresentationNeeded(_ needed: Bool) {
        presentationNeeded = needed
        syncPolling()
    }

    func refreshControlsEnabled() {
        syncPolling()
    }

    func refreshNow() async {
        await refreshNow(bypassingScriptBackoff: false)
    }

    private func refreshNow(bypassingScriptBackoff: Bool) async {
        guard shouldPoll else {
            clearStateForDisabledOrUnneeded()
            return
        }
        guard service.isNowPlayingPollingLikelyUseful else {
            clearStateForDisabledOrUnneeded()
            syncPolling()
            return
        }

        do {
            let snapshot = try await service.currentSnapshot(bypassingScriptBackoff: bypassingScriptBackoff)
            guard shouldPoll else {
                clearStateForDisabledOrUnneeded()
                return
            }
            guard service.isNowPlayingPollingLikelyUseful else {
                clearStateForDisabledOrUnneeded()
                syncPolling()
                return
            }
            consecutiveFailures = 0
            applyAvailableSnapshot(snapshot)
            syncPolling()
        } catch {
            guard shouldPoll else {
                clearStateForDisabledOrUnneeded()
                return
            }
            guard service.isNowPlayingPollingLikelyUseful else {
                clearStateForDisabledOrUnneeded()
                syncPolling()
                return
            }
            consecutiveFailures += 1
            applyUnavailable(reason: musicErrorMessage(error))
            syncPolling()
        }
    }

    func send(_ command: MusicCommand) async {
        guard controlsEnabled else {
            applySoftFailure(message: "Music controls are off", command: command)
            return
        }

        let stateBeforeCommand = state
        let didApplyOptimisticPlaybackState = applyOptimisticPlaybackState(for: command)

        do {
            try await service.send(command)
            softFailure = nil
            if didApplyOptimisticPlaybackState {
                schedulePostCommandRefresh()
            } else {
                await refreshNow(bypassingScriptBackoff: true)
            }
        } catch {
            if didApplyOptimisticPlaybackState {
                state = stateBeforeCommand
            }
            applySoftFailure(message: musicErrorMessage(error), command: command)
        }
    }

    func openCurrentPlayer() {
        guard controlsEnabled else {
            applySoftFailure(message: "Music controls are off", command: nil)
            return
        }
        guard let bundleIdentifier = snapshot?.player.bundleIdentifier else {
            applySoftFailure(message: "Music app unavailable", command: nil)
            return
        }
        guard MusicPlayerActivator.activate(bundleIdentifier: bundleIdentifier) else {
            applySoftFailure(message: "Music app unavailable", command: nil)
            return
        }
        guard softFailure != nil else { return }
        softFailure = nil
        markPublished()
    }

    private func applyOptimisticPlaybackState(for command: MusicCommand) -> Bool {
        guard command == .playPause,
              case let .available(snapshot?) = state,
              let playbackState = snapshot.playbackState.optimisticPlayPauseState else {
            return false
        }

        state = .available(snapshot.withPlaybackState(playbackState))
        softFailure = nil
        markPublished()
        return true
    }

    private func schedulePostCommandRefresh() {
        postCommandRefreshTask?.cancel()
        postCommandRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshNow(bypassingScriptBackoff: true)

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self.refreshNow(bypassingScriptBackoff: true)
            self.postCommandRefreshTask = nil
        }
    }

    private func applySoftFailure(message: String, command: MusicCommand?) {
        softFailure = MusicSoftFailure(
            message: message,
            command: command,
            occurredAt: now()
        )
        markPublished()
    }

    deinit {
        postCommandRefreshTask?.cancel()
        inFlightRefreshTask?.cancel()
    }

    private var controlsEnabled: Bool {
        defaults.object(forKey: SettingsKey.showMusicControls) == nil
            ? SettingsDefaults.showMusicControls
            : defaults.bool(forKey: SettingsKey.showMusicControls)
    }

    private var shouldPoll: Bool {
        MusicPollingPolicy.shouldPoll(
            controlsEnabled: controlsEnabled,
            presentationNeeded: presentationNeeded
        )
    }

    private func syncPolling() {
        guard shouldPoll else {
            scheduler.stop()
            activePollingInterval = nil
            inFlightRefreshTask?.cancel()
            inFlightRefreshTask = nil
            postCommandRefreshTask?.cancel()
            postCommandRefreshTask = nil
            clearStateForDisabledOrUnneeded()
            return
        }

        let nextInterval = MusicPollingPolicy.interval(
            consecutiveFailures: consecutiveFailures,
            playerAvailable: service.isNowPlayingPollingLikelyUseful
        )
        guard activePollingInterval != nextInterval else { return }

        activePollingInterval = nextInterval
        scheduler.start(every: nextInterval) { [weak self] in
            guard let self else { return }
            self.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        guard inFlightRefreshTask == nil else { return }
        inFlightRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshNow()
            self.inFlightRefreshTask = nil
        }
    }

    private func handlePollingAvailabilityChanged() {
        syncPolling()
        guard shouldPoll else { return }
        guard service.isNowPlayingPollingLikelyUseful else {
            inFlightRefreshTask?.cancel()
            inFlightRefreshTask = nil
            postCommandRefreshTask?.cancel()
            postCommandRefreshTask = nil
            clearStateForDisabledOrUnneeded()
            return
        }
        scheduleRefresh()
    }

    private func clearStateForDisabledOrUnneeded() {
        consecutiveFailures = 0
        softFailure = nil
        let target: MusicServiceState = controlsEnabled ? .available(nil) : .disabled
        guard state != target else { return }
        state = target
        markPublished()
    }

    private func applyAvailableSnapshot(_ snapshot: MusicNowPlayingSnapshot?) {
        let next = MusicServiceState.available(snapshot)
        guard !state.isDisplayEquivalent(to: next) else {
            guard softFailure != nil else { return }
            softFailure = nil
            markPublished()
            return
        }
        state = next
        softFailure = nil
        markPublished()
    }

    private func applyUnavailable(reason: String) {
        let next = MusicServiceState.unavailable(reason: reason)
        guard !state.isDisplayEquivalent(to: next) else { return }
        state = next
        markPublished()
    }

    private func markPublished() {
        publishRevision += 1
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func musicErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localized
        }
        return "Music service unavailable"
    }
}

private extension MusicServiceState {
    func isDisplayEquivalent(to other: MusicServiceState) -> Bool {
        switch (self, other) {
        case (.disabled, .disabled):
            return true
        case let (.unavailable(lhs), .unavailable(rhs)):
            return lhs == rhs
        case let (.available(lhs), .available(rhs)):
            switch (lhs, rhs) {
            case (.none, .none):
                return true
            case let (.some(lhs), .some(rhs)):
                return lhs.isDisplayEquivalent(to: rhs)
            default:
                return false
            }
        default:
            return false
        }
    }
}
