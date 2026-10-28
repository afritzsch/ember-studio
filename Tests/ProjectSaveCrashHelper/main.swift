import DAWModel
import Foundation

// MODEL-041/044/045: a process for the persistence tests to kill (Tests/DAWModelTests/
// ProjectCrashTests.swift). A real SIGKILL mid-write is the point, so this is its own process.
//
//   ProjectSaveCrashHelper save-loop <folder>
//       Saves a large project to <folder> once, then saves it again and again (its name is
//       "gen <n>") until killed. Each save replaces project.json through project.json.tmp.
//   ProjectSaveCrashHelper autosave <folder>
//       Saves an empty project named "saved", adds a track named "unsaved" without saving, waits
//       until the autosave has been written, prints "autosaved" and waits to be killed.

/// `tracks` audio tracks with `clips` clips each: a few MB of JSON, so a save takes long enough
/// to be killed in the middle of.
func largeProject(tracks: Int, clips: Int) -> Project {
    var project = Project(name: "gen 0")
    let asset = project.ids.allocate()
    project.assets = [AssetRef(id: asset, path: "Audio/missing.wav", channels: 2, originalSampleRate: 48_000, frames: 48_000)]
    for t in 0..<tracks {
        var track = Track(id: project.ids.allocate(), name: "Track \(t)", kind: .audio)
        for c in 0..<clips {
            track.clips.append(.audio(AudioClip(id: project.ids.allocate(), assetID: asset,
                                                start: Tick(Int64(c) * 1920), length: 960, gain: 0.5)))
        }
        project.tracks.append(track)
    }
    return project
}

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: ProjectSaveCrashHelper save-loop|autosave <folder>") }
let folder = URL(filePath: arguments[2])

switch arguments[1] {
case "save-loop":
    var project = largeProject(tracks: 200, clips: 60)
    let store = ProjectStore(project: project)
    store.autosavePolicy = nil
    do {
        try await store.save(to: folder)
        say("ready")
        var generation = 1
        while true {
            // A fresh store per generation: the name changes without an undo history to grow.
            project.name = "gen \(generation)"
            let next = ProjectStore(project: project)
            next.autosavePolicy = nil
            try await next.save(to: folder)
            generation += 1
        }
    } catch {
        fail("save failed: \(error)")
    }

case "autosave":
    let store = ProjectStore(project: Project(name: "saved"))
    store.autosavePolicy = AutosavePolicy(interval: .seconds(3600), debounce: .milliseconds(20))
    do {
        try await store.save(to: folder)
        try store.perform(AddTrack(name: "unsaved", kind: .audio))
    } catch {
        fail("\(error)")
    }
    let autosave = folder.appending(path: "autosave/project.json")
    while !FileManager.default.fileExists(atPath: autosave.path) {
        try await Task.sleep(for: .milliseconds(5))
    }
    say("autosaved")
    while true { try await Task.sleep(for: .seconds(60)) }

default:
    fail("unknown mode \(arguments[1])")
}
