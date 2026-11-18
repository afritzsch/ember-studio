/// Removes an asset no clip, take clip or sampler zone uses: the inverse of `ImportAsset`. Undo
/// removes the clips, takes and zones added after an import first, so a normal undo never meets a
/// used asset; a direct `RemoveAsset` of one is rejected (MODEL-031). DW-258 (T-099): take clips
/// count like clips, so Debug `validate()` never rejects the removal and Release never leaves a
/// take on a missing asset. The file stays where it is; the engine
/// keeps the decoded audio until the asset is gone from the graph.
public struct RemoveAsset: Command {
    public static let type = "RemoveAsset"

    public var assetID: ModelID

    public init(assetID: ModelID) {
        self.assetID = assetID
    }

    public var label: String { "Remove Asset" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.assetIndex(assetID) else { throw .notFound(kind: "asset", id: assetID) }
        for track in project.tracks {
            for case .audio(let clip) in track.clips where clip.assetID == assetID {
                throw .invalidArgument("asset \(assetID) is used by clip \(clip.id)")
            }
        }
        // DW-258 (T-099): a take folder's audio takes are clips too (refused like the track's).
        for track in project.tracks {
            for folder in track.takeFolders {
                for take in folder.takes {
                    if case .audio(let clip) = take.clip, clip.assetID == assetID {
                        throw .invalidArgument("asset \(assetID) is used by take \(take.id) (clip \(clip.id))")
                    }
                }
            }
        }
        // DW-140
        try project.forEachDeviceSlot { (slot, _) throws(DAWError) in
            if slot.zones.contains(where: { $0.assetID == assetID }) {
                throw .invalidArgument("asset \(assetID) is used by sampler \(slot.id)")
            }
        }
        return ImportAsset(asset: project.assets.remove(at: index), index: index)
    }
}
