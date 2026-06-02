import AppKit

struct SettingsBehaviorSpriteFrameCacheKey: Hashable {
    let animation: String
    let pointWidth: Int
    let pointHeight: Int
    let scale: Int
}

@MainActor
final class SettingsBehaviorSpriteFrameCache {
    static let shared = SettingsBehaviorSpriteFrameCache()

    private var storage: [SettingsBehaviorSpriteFrameCacheKey: [CGImage]] = [:]
    private var order: [SettingsBehaviorSpriteFrameCacheKey] = []
    private let limit = 24

    func frames(for spec: SettingsBehaviorSpriteSpec, pointSize: CGSize, scale: CGFloat) -> [CGImage]? {
        let key = SettingsBehaviorSpriteFrameCacheKey(
            animation: spec.animation.rawValue,
            pointWidth: Int((pointSize.width * 100).rounded()),
            pointHeight: Int((pointSize.height * 100).rounded()),
            scale: Int((scale * 100).rounded())
        )
        if let cached = storage[key] {
            return cached
        }
        guard let frames = loadFrames(for: spec, pointSize: pointSize, scale: scale) else {
            return nil
        }
        storage[key] = frames
        order.append(key)
        while order.count > limit {
            let removed = order.removeFirst()
            storage.removeValue(forKey: removed)
        }
        return frames
    }

    func clearForTesting() {
        storage.removeAll()
        order.removeAll()
    }

    private func loadFrames(for spec: SettingsBehaviorSpriteSpec, pointSize: CGSize, scale: CGFloat) -> [CGImage]? {
        guard let url = Bundle.appModule.url(
            forResource: spec.animation.rawValue + "-sheet",
            withExtension: "png",
            subdirectory: spec.resourceSubdirectory
        ),
              let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide == Int(spec.dimensions.width),
              bitmap.pixelsHigh == Int(spec.dimensions.height),
              let sheet = bitmap.cgImage else {
            return nil
        }

        var frames: [CGImage] = []
        frames.reserveCapacity(spec.frameCount)
        for index in 0..<spec.frameCount {
            let frameRect = CGRect(
                x: CGFloat(index) * spec.frameSize.width,
                y: 0,
                width: spec.frameSize.width,
                height: spec.frameSize.height
            )
            guard let cropped = sheet.cropping(to: frameRect),
                  let scaled = Self.scaledNearestFrame(cropped, pointSize: pointSize, scale: scale) else {
                return nil
            }
            frames.append(scaled)
        }
        return frames
    }

    private static func scaledNearestFrame(_ frame: CGImage, pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return context.makeImage()
    }
}
