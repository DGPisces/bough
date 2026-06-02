import AppKit
import QuartzCore
import SwiftUI

/// Renders the 4-frame Bough mascot sprite sheet
/// (Sources/Bough/Resources/bough-mascot/idle-sheet.png, 128×32 native
/// pixels = 4 frames of 32×32). Animated playback is layer-backed so it
/// matches the CLI mascot renderer's no-SwiftUI-tick performance profile.
struct BoughMascotView: View {
    /// Optional override; if nil, uses TimelineView animation index.
    var fixedFrame: Int? = nil

    /// Logical pixel size of one frame (defaults to native 32 pt).
    var frameSize: CGFloat = 32

    var body: some View {
        LayerBackedBoughMascotView(fixedFrame: fixedFrame, frameSize: frameSize)
            .frame(width: frameSize, height: frameSize)
    }

    /// Bundle: `Bundle.appModule` resolves to the SPM resource bundle inside
    /// a signed `.app` (Contents/Resources/Bough_Bough.bundle) and falls back
    /// to `Bundle.module` for SPM dev builds — see `BundleExtension.swift`.
    /// Project-wide convention used by `SoundManager` etc.
    fileprivate static let sheet: NSImage? = {
        guard let url = Bundle.appModule.url(
            forResource: "idle-sheet",
            withExtension: "png",
            subdirectory: "Resources/bough-mascot"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// Pure function: maps a Date to a frame index in 0..<4 at 0.4 s/frame.
    /// Exposed `internal` for tests.
    ///
    /// Uses microsecond-domain Int64 arithmetic to combine two correctness
    /// requirements:
    /// (1) IEEE 754 truncation safety. `0.4 * 1_000_000 = 400_000.0` is
    ///     exactly representable; `.rounded()` mops up any sub-ULP error
    ///     introduced by the seconds → microseconds conversion. Earlier
    ///     ms-domain `.rounded()` advanced frame boundaries up to 0.5 ms
    ///     early (a phase of 0.3995 s mapped to frame 1 before crossing
    ///     the 0.4 s edge); microsecond resolution removes that cliff.
    /// (2) Negative-date normalization. `truncatingRemainder` and Swift's
    ///     `%` both preserve sign, so dates before 2001-01-01 (the Apple
    ///     reference epoch) would otherwise return -1/-2/-3. The
    ///     `(x % cycle + cycle) % cycle` idiom normalizes any signed
    ///     value into [0, cycle).
    static func frameIndex(for date: Date) -> Int {
        let frameDurationUs: Int64 = 400_000          // 0.4 s in microseconds
        let cycleUs: Int64 = frameDurationUs * 4      // 1_600_000 (1.6 s)
        let totalUs = Int64((date.timeIntervalSinceReferenceDate * 1_000_000).rounded())
        let phaseUs = ((totalUs % cycleUs) + cycleUs) % cycleUs
        return Int(phaseUs / frameDurationUs)
    }
}

private struct LayerBackedBoughMascotView: NSViewRepresentable {
    let fixedFrame: Int?
    let frameSize: CGFloat

    func makeNSView(context: Context) -> LayerBackedBoughMascotNSView {
        let view = LayerBackedBoughMascotNSView()
        view.configure(fixedFrame: fixedFrame, frameSize: frameSize)
        return view
    }

    func updateNSView(_ nsView: LayerBackedBoughMascotNSView, context: Context) {
        nsView.configure(fixedFrame: fixedFrame, frameSize: frameSize)
    }
}

private final class LayerBackedBoughMascotNSView: NSView {
    private static let animationKey = "LayerBackedBoughMascotFrameAnimation"
    private static let frameDuration: TimeInterval = 0.4

    private let contentLayer = CALayer()
    private var fixedFrame: Int?
    private var pointSize: CGFloat = 32

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

    override var intrinsicContentSize: NSSize {
        NSSize(width: pointSize, height: pointSize)
    }

    override func layout() {
        super.layout()
        contentLayer.frame = bounds
    }

    func configure(fixedFrame: Int?, frameSize: CGFloat) {
        let sizeChanged = abs(pointSize - frameSize) > 0.001
        let frameChanged = self.fixedFrame != fixedFrame
        self.fixedFrame = fixedFrame
        self.pointSize = frameSize
        frame = NSRect(origin: frame.origin, size: NSSize(width: frameSize, height: frameSize))
        if sizeChanged {
            invalidateIntrinsicContentSize()
        }
        guard sizeChanged || frameChanged || contentLayer.contents == nil else { return }
        updatePlayback()
    }

    private func updatePlayback() {
        contentLayer.removeAnimation(forKey: Self.animationKey)
        guard let frames = BoughMascotFrameCache.shared.frames else {
            contentLayer.contents = nil
            contentLayer.backgroundColor = NSColor.gray.withAlphaComponent(0.5).cgColor
            return
        }
        contentLayer.backgroundColor = nil

        if let fixedFrame {
            contentLayer.contents = frames[Self.safeFrame(fixedFrame)]
            return
        }

        contentLayer.contents = frames.first
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = Double(frames.count) * Self.frameDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        contentLayer.add(animation, forKey: Self.animationKey)
    }

    private static func safeFrame(_ frame: Int) -> Int {
        max(0, min(3, frame))
    }
}

@MainActor
private final class BoughMascotFrameCache {
    static let shared = BoughMascotFrameCache()
    let frames: [CGImage]?

    private init() {
        guard let cgImage = BoughMascotView.sheet?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            frames = nil
            return
        }

        let frameWidth = cgImage.width / 4
        guard frameWidth > 0 else {
            frames = nil
            return
        }

        var croppedFrames: [CGImage] = []
        croppedFrames.reserveCapacity(4)
        for frame in 0..<4 {
            let rect = CGRect(x: frame * frameWidth, y: 0, width: frameWidth, height: cgImage.height)
            guard let cropped = cgImage.cropping(to: rect) else {
                frames = nil
                return
            }
            croppedFrames.append(cropped)
        }
        frames = croppedFrames
    }
}
