// Placeholder owned by 11-automation, which defines AutomationLane, ParamTarget and
// AutomationPoint here. Only an ID for now, so channels can hold lanes and encode them.
public struct AutomationLane: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID

    public init(id: ModelID) {
        self.id = id
    }
}
