/// What `ProjectStore.open` (and `loadAssets`) found while opening a project. The control
/// protocol's `project.open` returns it as `loadReport` (CTL-002, DW-107); the UI shows it.
public struct ProjectLoadReport: Hashable, Sendable, Codable {
    /// MODEL-046: assets whose file is missing (at open) or failed to load (`loadAssets`), sorted.
    /// They stay in the project with their clips, which render silence.
    public var offlineAssets: [ModelID]
    /// MODEL-042: the file's `formatVersion` when it was migrated on load, else nil.
    public var migratedFrom: Int?
    /// MODEL-045: the autosave was opened instead of `project.json`.
    public var recovered: Bool
    /// MODEL-045: `autosave/project.json` is newer than `project.json`, but recovery wasn't asked
    /// for. The UI offers it; the CLI reopens with `--recover`.
    public var recoveryAvailable: Bool
    /// DW-111: what open changed to make the project valid (MODEL-032), one line each.
    public var repairs: [String]

    public init(offlineAssets: [ModelID] = [], migratedFrom: Int? = nil, recovered: Bool = false,
                recoveryAvailable: Bool = false, repairs: [String] = []) {
        self.offlineAssets = offlineAssets
        self.migratedFrom = migratedFrom
        self.recovered = recovered
        self.recoveryAvailable = recoveryAvailable
        self.repairs = repairs
    }
}
