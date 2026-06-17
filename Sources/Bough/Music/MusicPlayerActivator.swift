import AppKit

enum MusicPlayerActivator {
    @discardableResult
    static func activate(bundleIdentifier: String) -> Bool {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var didRequestActivation = false
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == trimmed }) {
            if app.isHidden { app.unhide() }
            app.activate()
            didRequestActivation = true
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            didRequestActivation = true
        }
        return didRequestActivation
    }
}

extension MusicNowPlayingSnapshot {
    func withPlaybackState(_ playbackState: MusicPlaybackState) -> MusicNowPlayingSnapshot {
        MusicNowPlayingSnapshot(
            player: player,
            track: track,
            playbackState: playbackState,
            commands: commands,
            capturedAt: capturedAt,
            position: position
        )
    }
}

extension MusicPlaybackState {
    var optimisticPlayPauseState: MusicPlaybackState? {
        switch self {
        case .playing:
            return .paused
        case .paused:
            return .playing
        case .stopped, .unknown:
            return nil
        }
    }
}
