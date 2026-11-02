import DAWControl
import DAWModel
import Foundation
import Testing

// DW-146: inside test.fixture, a fixture's relative input paths (asset.import, project.open)
// resolve against the fixture's folder, not the server's working directory.

@Suite("test.fixture inputs (DW-146)")
struct FixtureAssetTests {
    @Test("DW-146: asset.import in a fixture finds assets/ next to the fixture; outside a fixture, the working directory")
    @MainActor
    func assetNextToFixture() async throws {
        let dir = try TempDir()
        let fixtures = dir.file("fx")
        try FileManager.default.createDirectory(at: fixtures.appending(path: "assets"), withIntermediateDirectories: true)
        try TestAudio.write([[0, 0.5, 0]], sampleRate: 48_000, to: fixtures.appending(path: "assets/a.wav"))
        try """
            project.new {"name": "f"}
            asset.import {"path": "assets/a.wav"}
            """.write(to: fixtures.appending(path: "imports.jsonl"), atomically: true, encoding: .utf8)
        let elsewhere = dir.file("cwd")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let (dispatcher, _) = TestDispatchers.fake(fixtures: [fixtures], workingDirectory: elsewhere)

        _ = try await dispatcher.ok(.testFixture, ["name": "imports"])
        let path = try await dispatcher.ok(.projectGet, ["path": "/assets/0/path"]).stringValue
        #expect(path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            == fixtures.appending(path: "assets/a.wav").resolvingSymlinksInPath())
        // After the fixture, relative paths are the working directory's again.
        let after = await dispatcher.failure(.assetImport, ["path": "assets/a.wav"])
        #expect(after?.dawError == "invalidArgument" && after?.message.contains(elsewhere.lastPathComponent) == true)
    }

    @Test("DW-146: dawctl runs a golden fixture that imports an asset from a folder that isn't the checkout")
    func goldenFixtureFromElsewhere() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../GoldenTests/fixtures").standardizedFileURL
        try #require(FileManager.default.fileExists(atPath: fixtures.appending(path: "wav_playback_resampled.jsonl").path))
        let dir = try TempDir()
        let run = try dawctl(["script", "-", "--fixtures", fixtures.path],
                             stdin: "test.fixture {\"name\": \"wav_playback_resampled\"}\nproject.get {\"path\": \"/assets\"}\n",
                             in: dir.url)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(try responses(run).last?.result?.arrayValue?.count == 1)
    }
}
