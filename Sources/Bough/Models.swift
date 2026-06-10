import Foundation
import BoughCore

struct PermissionRequest {
    let id = UUID()
    let event: HookEvent
    let continuation: CheckedContinuation<Data, Never>

    var toolUseId: String? { event.toolUseId }
    var toolUseKey: ToolUseKey? { ToolUseKey(event: event) }
    var dismissalId: String {
        if let toolUseKey { return "tool:\(toolUseKey.storageString)" }
        return "request:\(id.uuidString)"
    }
}

struct ToolUseKey: Hashable {
    let sessionId: String
    let source: String
    let toolUseId: String

    init?(event: HookEvent) {
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return nil }
        self.sessionId = event.sessionId ?? "default"
        self.source = Self.normalizedSource(from: event)
        self.toolUseId = toolUseId
    }

    var storageString: String {
        "\(sessionId):\(source):\(toolUseId)"
    }

    private static func normalizedSource(from event: HookEvent) -> String {
        let raw = event.rawJSON["_source"] as? String
        if let normalized = SessionSnapshot.normalizedSupportedSource(raw) {
            return normalized
        }
        return raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

struct AskUserQuestionItem {
    let payload: QuestionPayload
    let answerKey: String
    let multiSelect: Bool
}

enum AskUserQuestionAnswerValue {
    case single(String)
    case multiple([String])

    var jsonValue: Any {
        switch self {
        case .single(let value):
            return value
        case .multiple(let values):
            return values
        }
    }
}

struct AskUserQuestionState {
    let items: [AskUserQuestionItem]
    var answers: [String: String]

    var canConfirm: Bool {
        items.allSatisfy { answers[$0.answerKey] != nil }
    }

    mutating func select(questionIndex: Int, option: String) {
        guard items.indices.contains(questionIndex) else { return }
        answers[items[questionIndex].answerKey] = option
    }
}

struct QuestionRequest {
    let event: HookEvent
    let question: QuestionPayload
    let continuation: CheckedContinuation<Data, Never>
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool
    var askUserQuestionState: AskUserQuestionState?

    init(event: HookEvent, question: QuestionPayload, continuation: CheckedContinuation<Data, Never>, isFromPermission: Bool = false, askUserQuestionState: AskUserQuestionState? = nil) {
        self.event = event
        self.question = askUserQuestionState?.items.first?.payload ?? question
        self.continuation = continuation
        self.isFromPermission = isFromPermission
        self.askUserQuestionState = askUserQuestionState
    }
}
