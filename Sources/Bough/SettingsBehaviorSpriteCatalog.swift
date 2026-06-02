import CoreGraphics
import Foundation

enum SettingsBehaviorAnimation: String, CaseIterable {
    case hideFullscreen
    case hideNoSession
    case collapseMouseLeave
    case clickJumpCollapse
    case completionExpand
    case hapticHover
}

struct SettingsBehaviorSpriteSpec: Equatable {
    let animation: SettingsBehaviorAnimation
    let resourceSubdirectory: String
    let filename: String
    let frameSize: CGSize
    let frameCount: Int
    let frameInterval: TimeInterval
    let dimensions: CGSize
}

enum SettingsBehaviorSpriteCatalog {
    static let resourceSubdirectory = "Resources/settings-animations"
    static let frameSize = CGSize(width: 144, height: 96)
    static let frameCount = 48
    static let frameInterval: TimeInterval = 1.0 / 24.0

    static func spec(
        animation: SettingsBehaviorAnimation,
        bundle: Bundle = .appModule
    ) -> SettingsBehaviorSpriteSpec? {
        let filename = "\(animation.rawValue)-sheet.png"
        guard bundle.url(
            forResource: "\(animation.rawValue)-sheet",
            withExtension: "png",
            subdirectory: resourceSubdirectory
        ) != nil else {
            return nil
        }

        return SettingsBehaviorSpriteSpec(
            animation: animation,
            resourceSubdirectory: resourceSubdirectory,
            filename: filename,
            frameSize: frameSize,
            frameCount: frameCount,
            frameInterval: frameInterval,
            dimensions: CGSize(width: frameSize.width * CGFloat(frameCount), height: frameSize.height)
        )
    }
}
