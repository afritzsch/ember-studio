// Placeholder owned by 09-recording (REC-030..034), which defines TakeFolder, Take and CompSegment
// here. Only an ID for now, so tracks can hold take folders and encode them.
public struct TakeFolder: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID

    public init(id: ModelID) {
        self.id = id
    }
}
