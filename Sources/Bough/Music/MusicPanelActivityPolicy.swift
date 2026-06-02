import Foundation

enum MusicPanelActivitySource: Equatable {
    case aiActivity
    case music
}

enum MusicPanelActivityPolicy {
    static func hasVisibleMusicActivity(
        snapshot: MusicNowPlayingSnapshot?,
        musicControlsEnabled: Bool
    ) -> Bool {
        musicControlsEnabled && snapshot?.hasCurrentVisibleTrack == true
    }

    static func shouldShowPanel(
        hideWhenIdle: Bool,
        codingSessionsEnabled: Bool = true,
        activeSessionCount: Int,
        totalSessionCount: Int,
        hasVisibleMusicActivity: Bool
    ) -> Bool {
        if hasVisibleMusicActivity {
            return true
        }
        if !hideWhenIdle {
            return true
        }
        guard codingSessionsEnabled else {
            return false
        }
        guard totalSessionCount > 0 else {
            return false
        }
        return activeSessionCount > 0
    }

    static func shouldShowBar(
        hideWhenIdle: Bool,
        codingSessionsEnabled: Bool = true,
        activeSessionCount: Int,
        totalSessionCount: Int,
        hasVisibleMusicActivity: Bool
    ) -> Bool {
        if hasVisibleMusicActivity {
            return true
        }
        guard codingSessionsEnabled else {
            return false
        }
        guard totalSessionCount > 0 else {
            return false
        }
        return !(hideWhenIdle && activeSessionCount == 0)
    }

    static func shouldShowIdleIndicator(
        hideWhenIdle: Bool,
        codingSessionsEnabled: Bool = true,
        totalSessionCount: Int,
        hasVisibleMusicActivity: Bool
    ) -> Bool {
        codingSessionsEnabled && !hasVisibleMusicActivity && totalSessionCount == 0 && !hideWhenIdle
    }

    static func compactSource(
        rawPriority: String?,
        musicControlsEnabled: Bool,
        aiAvailable: Bool,
        musicAvailable: Bool,
        surface: IslandSurface
    ) -> MusicPanelActivitySource? {
        switch surface {
        case .approvalCard, .questionCard, .airDrop:
            return aiAvailable ? .aiActivity : nil
        case .collapsed:
            switch CompactBarPriority.resolvedSource(
                rawValue: rawPriority,
                musicControlsEnabled: musicControlsEnabled,
                aiAvailable: aiAvailable,
                musicAvailable: musicAvailable
            ) {
            case .aiActivity:
                return .aiActivity
            case .music:
                return .music
            case nil:
                return nil
            }
        case .sessionList, .completionCard:
            return aiAvailable ? .aiActivity : (musicAvailable ? .music : nil)
        }
    }

    static func presentationNeeded(
        musicControlsEnabled: Bool,
        hideWhenIdle: Bool,
        surface: IslandSurface
    ) -> Bool {
        musicControlsEnabled
    }
}
