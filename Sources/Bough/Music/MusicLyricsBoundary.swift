import Foundation

enum MusicLyricCandidateSource: Equatable {
    case mediaRemotePayload
    case officialNoTokenLocal
    case appleMusicScripting
    case tokenRequiredAPI
    case reverseEngineeredAPI
    case thirdPartySDK
    case unknown

    var isAllowed: Bool {
        switch self {
        case .mediaRemotePayload, .officialNoTokenLocal, .appleMusicScripting:
            return true
        case .tokenRequiredAPI, .reverseEngineeredAPI, .thirdPartySDK, .unknown:
            return false
        }
    }
}

struct MusicLyricCandidate: Equatable {
    let text: String?
    let source: MusicLyricCandidateSource
    let requiresToken: Bool

    init(text: String?, source: MusicLyricCandidateSource, requiresToken: Bool = false) {
        self.text = text
        self.source = source
        self.requiresToken = requiresToken
    }
}

enum MusicLyricsBoundary {
    static func oneLine(from candidates: [MusicLyricCandidate]) -> String? {
        for candidate in candidates where candidate.source.isAllowed && !candidate.requiresToken {
            if let line = firstNonEmptyLine(candidate.text) {
                return line
            }
        }
        return nil
    }

    private static func firstNonEmptyLine(_ value: String?) -> String? {
        value?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
