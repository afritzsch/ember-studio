import AVFoundation
import Foundation

/// Lists scan candidates without loading any plugin code.
public protocol PluginDiscovering: Sendable {
    func candidates() -> [PluginCandidate]
}

/// Discovery on this machine: AUs from the component manager (PLUG-002) and VST3 bundles from the
/// standard folders (PLUG-003). Both sources can be switched off or redirected for tests.
public struct SystemPluginDiscovery: PluginDiscovering {
    /// PLUG-002: the AU types the DAW hosts (effects, instruments, MIDI-controlled effects).
    public static let audioUnitTypes: [OSType] = [
        kAudioUnitType_Effect, kAudioUnitType_MusicDevice, kAudioUnitType_MusicEffect,
    ]

    /// PLUG-003: `/Library/Audio/Plug-Ins/VST3` and `~/Library/Audio/Plug-Ins/VST3`.
    public static var defaultVST3Directories: [URL] {
        [
            URL(filePath: "/Library/Audio/Plug-Ins/VST3", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Audio/Plug-Ins/VST3", directoryHint: .isDirectory),
        ]
    }

    public var vst3Directories: [URL]
    public var includeAudioUnits: Bool

    public init(
        vst3Directories: [URL] = SystemPluginDiscovery.defaultVST3Directories,
        includeAudioUnits: Bool = true
    ) {
        self.vst3Directories = vst3Directories
        self.includeAudioUnits = includeAudioUnits
    }

    public func candidates() -> [PluginCandidate] {
        (includeAudioUnits ? Self.audioUnitCandidates() : []) + Self.vst3Candidates(in: vst3Directories)
    }

    // MARK: Audio units

    /// PLUG-002: `AVAudioUnitComponentManager` lists AUv2 components and AUv3 app extensions alike.
    public static func audioUnitCandidates() -> [PluginCandidate] {
        let manager = AVAudioUnitComponentManager.shared()
        return audioUnitTypes.flatMap { type in
            manager.components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0,
                componentFlags: 0, componentFlagsMask: 0))
        }
        .map { component in
            PluginCandidate(
                format: .au,
                path: AudioUnitIdentifier(component.audioComponentDescription).description,
                mtime: 0,
                version: "\(component.versionString) (\(component.version))",
                name: component.name)
        }
    }

    // MARK: VST3

    /// PLUG-003: every `.vst3` bundle under `directories`, including vendor subfolders. Bundles
    /// aren't descended into, and missing directories are skipped.
    public static func vst3Candidates(in directories: [URL]) -> [PluginCandidate] {
        var candidates: [PluginCandidate] = []
        var seen = Set<String>()
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "vst3" else { continue }
                enumerator.skipDescendants()
                // Resolve symlinked bundles for the type check but key on the path as installed.
                let isDirectory = (try? url.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory, seen.insert(url.path).inserted else { continue }
                candidates.append(vst3Candidate(bundle: url))
            }
        }
        return candidates.sorted { $0.path < $1.path }
    }

    public static func vst3Candidate(bundle: URL) -> PluginCandidate {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        let infoURL = contents.appending(path: "Info.plist")
        // Read the plist directly: Bundle caches instances per path, so it would miss updates.
        let info = (try? Data(contentsOf: infoURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            as? [String: Any] ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String
        let buildVersion = info["CFBundleVersion"] as? String
        let version = switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build: "\(short) (\(build))"
        case let (short?, _): short
        case let (nil, build?): build
        case (nil, nil): ""
        }

        // PLUG-004: an update may rewrite only the binary or only the plist, so the key uses the
        // newest of the bundle, its Info.plist and its executable.
        var files = [bundle, infoURL]
        if let executable = info["CFBundleExecutable"] as? String {
            files.append(contents.appending(path: "MacOS/\(executable)"))
        }
        let mtime = files.compactMap { url -> Double? in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970
        }.max() ?? 0

        return PluginCandidate(
            format: .vst3, path: bundle.path, mtime: mtime, version: version,
            name: bundle.deletingPathExtension().lastPathComponent)
    }
}
