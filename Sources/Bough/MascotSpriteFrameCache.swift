import AppKit

struct MascotSpriteFrameCacheKey: Hashable {
    let sourceID: String
    let state: String
    let pointSize: Int
    let scale: Int
}

@MainActor
final class MascotSpriteFrameCache {
    static let shared = MascotSpriteFrameCache()

    private var storage: [MascotSpriteFrameCacheKey: [CGImage]] = [:]
    private var order: [MascotSpriteFrameCacheKey] = []
    private let limit = 48

    func frames(for spec: MascotSpriteSpec, pointSize: CGFloat, scale: CGFloat) -> [CGImage]? {
        let key = MascotSpriteFrameCacheKey(
            sourceID: spec.sourceID,
            state: spec.state.rawValue,
            pointSize: Int((pointSize * 100).rounded()),
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

    private func loadFrames(for spec: MascotSpriteSpec, pointSize: CGFloat, scale: CGFloat) -> [CGImage]? {
        guard let url = Bundle.appModule.url(
            forResource: spec.state.rawValue + "-sheet",
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
            let frameRect = CGRect(x: index * 32, y: 0, width: 32, height: 32)
            guard let cropped = sheet.cropping(to: frameRect),
                  let scaled = Self.scaledNearestFrame(cropped, pointSize: pointSize, scale: scale) else {
                return nil
            }
            frames.append(scaled)
        }
        return frames
    }

    private static func scaledNearestFrame(_ frame: CGImage, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let pixelSize = max(1, Int((pointSize * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        return context.makeImage()
    }
}
