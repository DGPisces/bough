import CoreGraphics
import Foundation
import BoughCore

enum MascotSpriteRuntimeState: String, CaseIterable {
    case idle
    case work
    case alert

    var frameCount: Int {
        switch self {
        case .idle:
            return 24
        case .work, .alert:
            return 32
        }
    }

    var frameInterval: TimeInterval {
        switch self {
        case .idle:
            return 0.05
        case .work:
            return 0.01
        case .alert:
            return 0.03
        }
    }

    var dimensions: CGSize {
        CGSize(width: frameCount * 32, height: 32)
    }

    var filename: String {
        "\(rawValue)-sheet.png"
    }
}

struct MascotSpriteSpec: Equatable {
    let sourceID: String
    let state: MascotSpriteRuntimeState
    let resourceSubdirectory: String
    let filename: String
    let frameCount: Int
    let frameInterval: TimeInterval
    let dimensions: CGSize
}

enum MascotSpriteCatalog {
    static let fallbackSourceID = "claude"

    static let approvedSourceIDs: Set<String> = [
        "antigravity",
        "claude",
        "codebuddy",
        "codex",
        "copilot",
        "cursor",
        "droid",
        "gemini",
        "hermes",
        "kimi",
        "opencode",
        "qoder",
        "qwen",
        "stepfun",
        "trae",
        "workbuddy",
    ]

    private static let sourceAliases: [String: String] = [
        "codybuddycn": "codebuddy",
        "cursor-cli": "cursor",
        "qoder-cli": "qoder",
        "traecn": "trae",
        "traecli": "trae",
    ]

    static func spec(source: String, status: AgentStatus, bundle: Bundle = .appModule) -> MascotSpriteSpec? {
        guard let sourceID = normalizedApprovedSourceID(source) else {
            return nil
        }
        let state = runtimeState(for: status)
        let subdirectory = "Resources/mascots/\(sourceID)"

        guard bundle.url(
            forResource: state.rawValue + "-sheet",
            withExtension: "png",
            subdirectory: subdirectory
        ) != nil else {
            return nil
        }

        return MascotSpriteSpec(
            sourceID: sourceID,
            state: state,
            resourceSubdirectory: subdirectory,
            filename: state.filename,
            frameCount: state.frameCount,
            frameInterval: state.frameInterval,
            dimensions: state.dimensions
        )
    }

    static func fallbackSpec(status: AgentStatus, bundle: Bundle = .appModule) -> MascotSpriteSpec? {
        spec(source: fallbackSourceID, status: status, bundle: bundle)
    }

    static func iconURL(source: String, bundle: Bundle = .appModule) -> URL? {
        guard let sourceID = normalizedApprovedSourceID(source) else {
            return nil
        }
        return bundle.url(
            forResource: "icon",
            withExtension: "png",
            subdirectory: "Resources/mascots/\(sourceID)"
        )
    }

    static func normalizedApprovedSourceID(_ source: String) -> String? {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceID = sourceAliases[normalized] ?? normalized
        return approvedSourceIDs.contains(sourceID) ? sourceID : nil
    }

    static func runtimeState(for status: AgentStatus) -> MascotSpriteRuntimeState {
        switch status {
        case .idle:
            return .idle
        case .processing, .running:
            return .work
        case .waitingApproval, .waitingQuestion:
            return .alert
        }
    }
}
