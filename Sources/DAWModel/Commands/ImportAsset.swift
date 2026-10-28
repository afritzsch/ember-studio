/// MODEL-005 (DW-105, DW-043): adds an asset the engine has loaded. The wire shape is what
/// `asset.import` (13) performs: `{"type": "ImportAsset", "asset": AssetRef}`. The asset keeps its
/// ID, which the caller took from `project.ids.next` to load it under before performing this, so
/// the ID is checked (unused, in range) and reserved rather than allocated.
///
/// The command records the import; it doesn't do it. Copying the file into `Audio/`
/// (`AudioImporter::importFile`, IO-030) and decoding it happen before, outside the model: a command
/// is replayed on redo and decoded from JSON, so file I/O here would run again on every redo and
/// could fail there, and DAWModel reaches the engine only through `EngineProtocol`. `asset.path` is
/// whatever the importer reports: the project-relative path when the file is in the project folder,
/// otherwise the absolute path (a referenced file, or a project with no folder yet).
public struct ImportAsset: Command {
    public static let type = "ImportAsset"

    public var asset: AssetRef
    /// Position in `project.assets`. Default: the end. Undo of `RemoveAsset` uses it to put the
    /// asset back where it was.
    public var index: Int?

    public init(asset: AssetRef, index: Int? = nil) {
        self.asset = asset
        self.index = index
    }

    public var label: String { "Import Asset" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let index = index ?? project.assets.count
        guard (0...project.assets.count).contains(index) else {
            throw .invalidArgument("asset index \(index) is outside 0…\(project.assets.count)")
        }
        try asset.validate()
        try project.claimIDs { body in body(asset.id, "asset") }
        project.assets.insert(asset, at: index)
        return RemoveAsset(assetID: asset.id)
    }
}
