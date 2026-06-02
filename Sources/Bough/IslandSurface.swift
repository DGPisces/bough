/// 面板当前展示的 "面"——同一时刻只能有一个
enum AirDropReturnSurface: Equatable {
    case collapsed
    case sessionList
    case completionCard(sessionId: String)

    var surface: IslandSurface {
        switch self {
        case .collapsed:
            return .collapsed
        case .sessionList:
            return .sessionList
        case .completionCard(let sessionId):
            return .completionCard(sessionId: sessionId)
        }
    }
}

enum IslandSurface: Equatable {
    /// 收起状态，只显示 compact bar
    case collapsed
    /// 用户主动展开，显示 session 列表
    case sessionList
    /// 显示 AirDrop 专属模式
    case airDrop(returningTo: AirDropReturnSurface)
    /// 显示权限审批卡片
    case approvalCard(sessionId: String)
    /// 显示问答卡片
    case questionCard(sessionId: String)
    /// 自动展开显示完成通知
    case completionCard(sessionId: String)

    var isExpanded: Bool { self != .collapsed }

    /// 当前 surface 关联的 session ID（如有）
    var sessionId: String? {
        switch self {
        case .collapsed, .sessionList, .airDrop: return nil
        case .approvalCard(let id), .questionCard(let id), .completionCard(let id): return id
        }
    }
}
