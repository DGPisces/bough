import AppKit
import QuartzCore
import SwiftUI

@MainActor
struct SettingsBehaviorSpriteView: NSViewRepresentable {
    let animation: SettingsBehaviorAnimation
    var size: CGSize = SettingsBehaviorSpriteCatalog.frameSize

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeNSView(context: Context) -> SettingsBehaviorSpriteNSView {
        let view = SettingsBehaviorSpriteNSView()
        view.configure(
            animation: animation,
            size: size,
            accessibilityReduceMotion: accessibilityReduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: SettingsBehaviorSpriteNSView, context: Context) {
        nsView.configure(
            animation: animation,
            size: size,
            accessibilityReduceMotion: accessibilityReduceMotion
        )
    }
}

enum SettingsBehaviorSpritePlaybackMode: Equatable {
    case animated
    case staticFrame
}

enum SettingsBehaviorSpritePlaybackPolicy {
    static func mode(
        isVisible: Bool,
        accessibilityReduceMotion: Bool,
        frameCount: Int
    ) -> SettingsBehaviorSpritePlaybackMode {
        guard isVisible, !accessibilityReduceMotion, frameCount > 1 else {
            return .staticFrame
        }
        return .animated
    }
}

@MainActor
final class SettingsBehaviorSpriteNSView: NSView {
    private static let animationKey = "SettingsBehaviorFrameAnimation"

    private let contentLayer = CALayer()
    private var animation: SettingsBehaviorAnimation?
    private var pointSize = SettingsBehaviorSpriteCatalog.frameSize
    private var accessibilityReduceMotion = false
    private var scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    private var windowObservers: [NSObjectProtocol] = []
    private var animationSignature: SettingsBehaviorSpriteAnimationSignature?

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
        NSSize(width: pointSize.width, height: pointSize.height)
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

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func configure(
        animation: SettingsBehaviorAnimation,
        size: CGSize,
        accessibilityReduceMotion: Bool
    ) {
        let nextScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? scale
        let sizeChanged = abs(pointSize.width - size.width) > 0.001
            || abs(pointSize.height - size.height) > 0.001
        let changed = self.animation != animation
            || sizeChanged
            || self.accessibilityReduceMotion != accessibilityReduceMotion
            || abs(scale - nextScale) > 0.001

        self.animation = animation
        self.pointSize = size
        self.accessibilityReduceMotion = accessibilityReduceMotion
        self.scale = nextScale
        frame = NSRect(origin: frame.origin, size: NSSize(width: size.width, height: size.height))
        if sizeChanged {
            invalidateIntrinsicContentSize()
        }

        if changed {
            syncPlayback()
        }
    }

    var hasRunningAnimationForTesting: Bool {
        contentLayer.animation(forKey: Self.animationKey) != nil
    }

    private func syncPlayback() {
        contentLayer.removeAnimation(forKey: Self.animationKey)
        animationSignature = nil

        guard let animation,
              let spec = SettingsBehaviorSpriteCatalog.spec(animation: animation),
              let frames = SettingsBehaviorSpriteFrameCache.shared.frames(
                for: spec,
                pointSize: pointSize,
                scale: scale
              ) else {
            contentLayer.contents = nil
            return
        }

        contentLayer.contentsScale = scale
        contentLayer.contents = frames.first

        let mode = SettingsBehaviorSpritePlaybackPolicy.mode(
            isVisible: isWindowVisible,
            accessibilityReduceMotion: accessibilityReduceMotion,
            frameCount: spec.frameCount
        )
        guard mode == .animated else {
            return
        }

        installAnimation(frames: frames, spec: spec)
    }

    private func installAnimation(frames: [CGImage], spec: SettingsBehaviorSpriteSpec) {
        let signature = SettingsBehaviorSpriteAnimationSignature(
            animation: spec.animation.rawValue,
            pointWidth: Int((pointSize.width * 100).rounded()),
            pointHeight: Int((pointSize.height * 100).rounded()),
            scale: Int((scale * 100).rounded()),
            frameCount: spec.frameCount
        )
        if animationSignature == signature,
           contentLayer.animation(forKey: Self.animationKey) != nil {
            return
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = Double(spec.frameCount) * spec.frameInterval
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
                Task { @MainActor in
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

struct SettingsBehaviorSpriteAnimationSignature: Hashable {
    let animation: String
    let pointWidth: Int
    let pointHeight: Int
    let scale: Int
    let frameCount: Int
}
