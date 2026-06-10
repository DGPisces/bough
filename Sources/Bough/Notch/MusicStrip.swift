import AppKit
import SwiftUI

enum MusicArtworkTransitionID {
    static let artwork = "music-artwork"
    static let playPause = "music-play-pause"
    static let zIndex: Double = 1_000
}

struct MusicStripModel: Equatable {
    static let artworkSize: CGFloat = 46
    static let compactFigureSize: CGFloat = 27
    static let controlSize: CGFloat = 26
    static let compactControlSize: CGFloat = 24
    static let lyricLineHeight: CGFloat = 14

    let title: String
    let subtitle: String
    let lyricLine: String?
    let artwork: MusicArtworkSnapshot?
    let playbackState: MusicPlaybackState
    let commands: MusicCommandAvailability
    let failedCommand: MusicCommand?
    let playerBundleIdentifier: String?

    init?(snapshot: MusicNowPlayingSnapshot?, softFailure: MusicSoftFailure? = nil) {
        guard let snapshot, snapshot.hasCurrentVisibleTrack else {
            return nil
        }

        let track = snapshot.track
        title = track?.title ?? track?.album ?? snapshot.player.displayName

        if let artist = track?.artist {
            subtitle = "\(artist) · \(snapshot.player.displayName)"
        } else if let album = track?.album {
            subtitle = "\(album) · \(snapshot.player.displayName)"
        } else {
            subtitle = snapshot.player.displayName
        }

        lyricLine = track?.lyricLine
        artwork = track?.artwork
        playbackState = snapshot.playbackState
        commands = snapshot.commands
        failedCommand = softFailure?.command
        playerBundleIdentifier = snapshot.player.bundleIdentifier
    }

    var isPlaying: Bool {
        playbackState == .playing
    }

    var playPauseIcon: String {
        isPlaying ? "pause.fill" : "play.fill"
    }

    var playPauseLabelKey: String {
        isPlaying ? "music_pause" : "music_play"
    }

    var reservedLyricText: String {
        lyricLine ?? " "
    }

    var lyricOpacity: Double {
        lyricLine == nil ? 0 : 1
    }

    var hasSoftFailure: Bool {
        failedCommand != nil
    }

    static func shouldShowExpanded(
        surface: IslandSurface,
        onlySessionId: String?,
        snapshot: MusicNowPlayingSnapshot?,
        musicControlsEnabled: Bool
    ) -> Bool {
        guard onlySessionId == nil else { return false }
        guard case .sessionList = surface else { return false }
        return MusicPanelActivityPolicy.hasVisibleMusicActivity(
            snapshot: snapshot,
            musicControlsEnabled: musicControlsEnabled
        )
    }
}

@MainActor
struct MusicStrip: View {
    var appState: AppState
    var musicArtworkNamespace: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if let model = MusicStripModel(
            snapshot: appState.musicStore.snapshot,
            softFailure: appState.musicStore.softFailure
        ) {
            HStack(spacing: 10) {
                if let musicArtworkNamespace {
                    artworkButton(model: model)
                        .matchedGeometryEffect(id: MusicArtworkTransitionID.artwork, in: musicArtworkNamespace)
                        .zIndex(MusicArtworkTransitionID.zIndex)
                } else {
                    artworkButton(model: model)
                }

                VStack(alignment: .leading, spacing: 3) {
                    if reduceMotion {
                        Text(model.title)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        MorphText(
                            text: model.title,
                            font: .system(size: 12, weight: .semibold, design: .monospaced),
                            color: .white.opacity(0.9),
                            lineLimit: 1
                        )
                        .truncationMode(.tail)
                    }

                    Text(model.subtitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(model.reservedLyricText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: MusicStripModel.lyricLineHeight, alignment: .leading)
                        .opacity(model.lyricOpacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()

                HStack(spacing: 5) {
                    MusicControlButton(
                        icon: "backward.fill",
                        label: l10n["music_previous"],
                        isEnabled: model.commands.supports(.previous),
                        isFailed: model.failedCommand == .previous,
                        size: MusicStripModel.controlSize
                    ) {
                        Task { await appState.musicStore.send(.previous) }
                    }

                    if let musicArtworkNamespace {
                        playPauseButton(model: model)
                            .matchedGeometryEffect(id: MusicArtworkTransitionID.playPause, in: musicArtworkNamespace)
                            .zIndex(MusicArtworkTransitionID.zIndex)
                    } else {
                        playPauseButton(model: model)
                    }

                    MusicControlButton(
                        icon: "forward.fill",
                        label: l10n["music_next"],
                        isEnabled: model.commands.supports(.next),
                        isFailed: model.failedCommand == .next,
                        size: MusicStripModel.controlSize
                    ) {
                        Task { await appState.musicStore.send(.next) }
                    }
                }
                .frame(width: 88, alignment: .trailing)
            }
            .frame(minHeight: 58)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(model.hasSoftFailure ? 0.075 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        model.hasSoftFailure ? Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.38) : .white.opacity(0.08),
                        lineWidth: model.hasSoftFailure ? 1.2 : 1
                    )
            )
            .padding(.horizontal, 6)
            .transition(reduceMotion ? .opacity : .blurFade.combined(with: .move(edge: .top)))
        }
    }

    private func artworkButton(model: MusicStripModel) -> some View {
        Button {
            appState.musicStore.openCurrentPlayer()
        } label: {
            MusicArtworkTile(
                artwork: model.artwork,
                size: MusicStripModel.artworkSize,
                accessibilityLabel: l10n["music_artwork_fallback"]
            )
        }
        .buttonStyle(.plain)
        .disabled(model.playerBundleIdentifier == nil)
        .help(l10n["music_open_player"])
        .accessibilityLabel(l10n["music_open_player"])
    }

    private func playPauseButton(model: MusicStripModel) -> some View {
        MusicControlButton(
            icon: model.playPauseIcon,
            label: l10n[model.playPauseLabelKey],
            isEnabled: model.commands.supports(.playPause),
            isFailed: model.failedCommand == .playPause,
            size: MusicStripModel.controlSize,
            prominent: true
        ) {
            Task { await appState.musicStore.send(.playPause) }
        }
    }
}

@MainActor
struct CompactMusicPlayPauseControl: View {
    var appState: AppState
    var musicArtworkNamespace: Namespace.ID?
    var onHoverChanged: ((Bool) -> Void)?
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        if let model = MusicStripModel(
            snapshot: appState.musicStore.snapshot,
            softFailure: appState.musicStore.softFailure
        ) {
            if let musicArtworkNamespace {
                playPauseButton(model: model)
                    .matchedGeometryEffect(id: MusicArtworkTransitionID.playPause, in: musicArtworkNamespace)
                    .zIndex(MusicArtworkTransitionID.zIndex)
            } else {
                playPauseButton(model: model)
            }
        }
    }

    private func playPauseButton(model: MusicStripModel) -> some View {
        MusicControlButton(
            icon: model.playPauseIcon,
            label: l10n[model.playPauseLabelKey],
            isEnabled: model.commands.supports(.playPause),
            isFailed: model.failedCommand == .playPause,
            size: MusicStripModel.compactControlSize,
            prominent: true,
            onHoverChanged: onHoverChanged
        ) {
            Task { await appState.musicStore.send(.playPause) }
        }
    }
}

struct MusicFigureView: View {
    let snapshot: MusicNowPlayingSnapshot?
    var size: CGFloat = MusicStripModel.compactFigureSize
    @ObservedObject private var l10n = L10n.shared

    private var model: MusicStripModel? {
        MusicStripModel(snapshot: snapshot)
    }

    private var isPlaying: Bool {
        model?.isPlaying == true
    }

    var body: some View {
        ZStack {
            MusicArtworkTile(
                artwork: model?.artwork,
                size: size,
                accessibilityLabel: l10n["music_artwork_fallback"]
            )
            .saturation(isPlaying ? 1 : 0)
            .brightness(isPlaying ? 0 : -0.12)
            .opacity(isPlaying ? 1 : 0.62)
            .overlay {
                if !isPlaying {
                    Circle()
                        .fill(.black.opacity(0.42))
                        .frame(width: size * 0.58, height: size * 0.58)
                    Image(systemName: "pause.fill")
                        .font(.system(size: max(9, size * 0.32), weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(isPlaying ? 0.18 : 0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .compositingGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model?.title ?? l10n["music_unknown_title"])
        .frame(width: size, height: size)
        .clipped()
    }
}

private struct MusicArtworkTile: View {
    let artwork: MusicArtworkSnapshot?
    let size: CGFloat
    let accessibilityLabel: String
    @State private var decodedArtwork: MusicArtworkSnapshot?
    @State private var decodedImage: NSImage?

    init(artwork: MusicArtworkSnapshot?, size: CGFloat, accessibilityLabel: String) {
        self.artwork = artwork
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        _decodedArtwork = State(initialValue: nil)
        _decodedImage = State(initialValue: nil)
    }

    var body: some View {
        ZStack {
            if let decodedImage {
                Image(nsImage: decodedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.08))
                Image(systemName: "music.note")
                    .font(.system(size: size > 32 ? 18 : 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: artwork, initial: true) { _, newValue in
            guard decodedArtwork != newValue else { return }
            decodedArtwork = newValue
            decodedImage = newValue.flatMap { NSImage(data: $0.data) }
        }
    }
}

private struct MusicControlButton: View {
    let icon: String
    let label: String
    let isEnabled: Bool
    let isFailed: Bool
    let size: CGFloat
    var prominent = false
    var onHoverChanged: ((Bool) -> Void)?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var foregroundOpacity: Double {
        guard isEnabled else { return 0.24 }
        return hovering || prominent ? 0.96 : 0.72
    }

    private var fillOpacity: Double {
        guard isEnabled else { return 0.03 }
        if isFailed { return 0.18 }
        if prominent { return hovering ? 0.18 : 0.12 }
        return hovering ? 0.12 : 0.06
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 11 : 10, weight: .semibold))
                .foregroundStyle((isFailed ? Color(red: 1.0, green: 0.42, blue: 0.42) : Color.white).opacity(foregroundOpacity))
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill((isFailed ? Color(red: 1.0, green: 0.42, blue: 0.42) : Color.white).opacity(fillOpacity))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isFailed ? Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.45) : .white.opacity(hovering ? 0.18 : 0.08),
                            lineWidth: 1
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { h in
            onHoverChanged?(h)
            if reduceMotion {
                hovering = h
            } else {
                withAnimation(NotchAnimation.micro) { hovering = h }
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}
