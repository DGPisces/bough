import AppKit
import QuartzCore
import SwiftUI

@MainActor
struct SpriteMascotView: NSViewRepresentable {
    let spec: MascotSpriteSpec
    let size: CGFloat
    let mascotSpeed: Double

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeNSView(context: Context) -> SpriteMascotNSView {
        let view = SpriteMascotNSView()
        view.configure(
            spec: spec,
            size: size,
            mascotSpeed: mascotSpeed,
            accessibilityReduceMotion: accessibilityReduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: SpriteMascotNSView, context: Context) {
        nsView.configure(
            spec: spec,
            size: size,
            mascotSpeed: mascotSpeed,
            accessibilityReduceMotion: accessibilityReduceMotion
        )
    }
}

enum MascotSpritePlaybackMode: Equatable {
    case animated
    case staticFrame
}

enum MascotSpritePlaybackPolicy {
    static func mode(
        isVisible: Bool,
        mascotSpeed: Double,
        accessibilityReduceMotion: Bool,
        frameCount: Int
    ) -> MascotSpritePlaybackMode {
        guard isVisible else {
            return .staticFrame
        }
        if mascotSpeed == 0 {
            return .staticFrame
        }
        if accessibilityReduceMotion {
            return .staticFrame
        }
        return frameCount > 1 ? .animated : .staticFrame
    }
}

@MainActor
final class SpriteMascotNSView: NSView {
    private static let animationKey = "SpriteMascotFrameAnimation"

    private let contentLayer = CALayer()
    private var spec: MascotSpriteSpec?
    private var pointSize: CGFloat = 27
    private var mascotSpeed: Double = 1
    private var accessibilityReduceMotion = false
    private var scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    private var windowObservers: [NSObjectProtocol] = []
    private var animationSignature: MascotSpriteAnimationSignature?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.magnificationFilter = .nearest
        contentLayer.minificationFilter = .nearest
        layer?.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        didSet {
            if oldValue != isHidden {
                syncPlayback()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: pointSize, height: pointSize)
    }

    override func layout() {
        super.layout()
        contentLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        syncPlayback()
    }

    func configure(
        spec: MascotSpriteSpec,
        size: CGFloat,
        mascotSpeed: Double,
        accessibilityReduceMotion: Bool
    ) {
        let normalizedSpeed = max(0, mascotSpeed)
        let nextScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? scale
        let sizeChanged = abs(pointSize - size) > 0.001
        let changed = self.spec != spec
            || sizeChanged
            || abs(self.mascotSpeed - normalizedSpeed) > 0.001
            || self.accessibilityReduceMotion != accessibilityReduceMotion
            || abs(scale - nextScale) > 0.001

        self.spec = spec
        self.pointSize = size
        self.mascotSpeed = normalizedSpeed
        self.accessibilityReduceMotion = accessibilityReduceMotion
        self.scale = nextScale
        frame = NSRect(origin: frame.origin, size: NSSize(width: size, height: size))
        if sizeChanged {
            invalidateIntrinsicContentSize()
        }

        if changed {
            syncPlayback()
        }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var hasRunningAnimationForTesting: Bool {
        contentLayer.animation(forKey: Self.animationKey) != nil
    }

    private func syncPlayback() {
        contentLayer.removeAnimation(forKey: Self.animationKey)
        animationSignature = nil

        guard let spec else {
            contentLayer.contents = nil
            return
        }

        guard let frames = MascotSpriteFrameCache.shared.frames(
            for: spec,
            pointSize: pointSize,
            scale: scale
        ) else {
            contentLayer.contents = nil
            return
        }

        contentLayer.contentsScale = scale
        contentLayer.contents = frames.first

        let mode = MascotSpritePlaybackPolicy.mode(
            isVisible: isWindowVisible,
            mascotSpeed: mascotSpeed,
            accessibilityReduceMotion: accessibilityReduceMotion,
            frameCount: spec.frameCount
        )
        guard mode == .animated else {
            return
        }

        installAnimation(frames: frames, spec: spec)
    }

    private func installAnimation(frames: [CGImage], spec: MascotSpriteSpec) {
        let signature = MascotSpriteAnimationSignature(
            sourceID: spec.sourceID,
            state: spec.state.rawValue,
            pointSize: Int((pointSize * 100).rounded()),
            scale: Int((scale * 100).rounded()),
            mascotSpeed: Int((mascotSpeed * 1000).rounded()),
            frameCount: spec.frameCount
        )
        if animationSignature == signature,
           contentLayer.animation(forKey: Self.animationKey) != nil {
            return
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = Double(spec.frameCount) * spec.frameInterval / mascotSpeed
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        contentLayer.add(animation, forKey: Self.animationKey)
        animationSignature = signature
    }

    private var isWindowVisible: Bool {
        guard let window else { return false }
        return window.isVisible
            && window.occlusionState.contains(.visible)
            && !NSApp.isHidden
            && !isHidden
    }

    private func installWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()

        let center = NotificationCenter.default
        for (name, object) in playbackVisibilityNotifications() {
            let observer = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncPlayback()
                }
            }
            windowObservers.append(observer)
        }
    }

    private func playbackVisibilityNotifications() -> [(Notification.Name, Any?)] {
        var notifications: [(Notification.Name, Any?)] = [
            (NSApplication.didHideNotification, NSApp),
            (NSApplication.didUnhideNotification, NSApp),
        ]
        if let window {
            notifications.append(contentsOf: [
                (NSWindow.didChangeOcclusionStateNotification, window),
                (NSWindow.didMiniaturizeNotification, window),
                (NSWindow.didDeminiaturizeNotification, window),
            ])
        }
        return notifications
    }
}

struct MascotSpriteAnimationSignature: Hashable {
    let sourceID: String
    let state: String
    let pointSize: Int
    let scale: Int
    let mascotSpeed: Int
    let frameCount: Int
}
