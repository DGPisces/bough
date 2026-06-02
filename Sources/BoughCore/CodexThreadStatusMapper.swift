public enum CodexThreadStatusMapper {
    public static func apply(
        _ snapshot: inout SessionSnapshot,
        status: [String: AnyCodableLike]?
    ) {
        guard let typeLabel = status?["type"]?.asString else { return }
        switch typeLabel {
        case "active":
            let flags: [AnyCodableLike]
            if case .array(let a) = status?["activeFlags"] ?? .null { flags = a } else { flags = [] }
            let flagStrings = flags.compactMap { $0.asString }
            if flagStrings.contains("waitingOnApproval") {
                snapshot.status = .waitingApproval
            } else if flagStrings.contains("waitingOnUserInput") {
                snapshot.status = .waitingQuestion
            } else {
                snapshot.status = .running
                snapshot.currentTool = nil
                snapshot.toolDescription = nil
            }
        case "idle":
            snapshot.status = .idle
            snapshot.currentTool = nil
            snapshot.toolDescription = nil
        case "systemError", "notLoaded":
            snapshot.status = .idle
        default:
            break
        }
    }
}
