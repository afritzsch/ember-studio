import DAWModel
import Foundation

/// T-093 (DW-216, REC-011): a MIDI track's input picker, in its header and on its mixer strip (the
/// strip shows the header's controls, DW-202). It lists "All Inputs", the engine's MIDI sources
/// (`midi.inputs`) and, if the track's source isn't among the connected ones, that source as "not
/// connected" (DECISIONS "T-093 model shape": the selection stays and delivers nothing). The
/// channel is Omni or 1…16. Picking performs `SetTrackMidiInput` (undoable).
///
/// Controls (UI-052): `track.<id>.midiInput.source.all`, `track.<id>.midiInput.source.<uniqueID>`
/// and `track.<id>.midiInput.channel.<0…16>` (0 = Omni), all toggles.
struct TrackMidiInputMenu: Equatable {
    let input: Track.MidiInput
    /// The selected source's name ("All Inputs", the source's name, or "Source <id>" when the
    /// engine doesn't know it).
    let sourceName: String
    /// Whether the selected source is connected (always true for all sources).
    let connected: Bool
    let sourceControls: [UIControl]
    let channelControls: [UIControl]

    var controls: [UIControl] { sourceControls + channelControls }

    /// The menu's face: "All · Omni", "Keystation · Ch 3", "⚠ Keystation · Omni" when not connected.
    var title: String {
        "\(connected ? "" : "⚠ ")\(sourceName) · \(Self.channelTitle(input.channel))"
    }

    static func channelTitle(_ channel: UInt8) -> String { channel == 0 ? "Omni" : "Ch \(channel)" }

    static func == (a: TrackMidiInputMenu, b: TrackMidiInputMenu) -> Bool {
        a.input == b.input && a.sourceName == b.sourceName && a.connected == b.connected
            && a.controls.map(\.id) == b.controls.map(\.id)
    }

    /// nil for an audio track.
    @MainActor
    static func make(for track: Track, inputs: [MidiInputInfo], perform: @escaping @MainActor (any Command) -> Void)
        -> TrackMidiInputMenu?
    {
        guard track.kind == .midi else { return nil }
        let current = track.midiInput
        let prefix = "track.\(track.id).midiInput"
        func pick(_ input: Track.MidiInput) -> @MainActor () -> Void {
            { if input != current { perform(SetTrackMidiInput(trackID: track.id, input)) } }
        }

        var sources: [UIControl] = [
            .toggle("\(prefix).source.all", "MIDI Input All Inputs", isOn: current.source == .all,
                    action: pick(Track.MidiInput(source: .all, channel: current.channel))),
        ]
        // One entry per unique ID (CoreMIDI may list a source twice while it reconnects).
        var seen = Set<Int32>()
        for info in inputs where seen.insert(info.uniqueID).inserted {
            let source = Track.MidiInput.Source.device(info.uniqueID)
            let label = "MIDI Input \(info.name)\(info.connected ? "" : " (not connected)")"
            sources.append(.toggle("\(prefix).source.\(info.uniqueID)", label, isOn: current.source == source,
                                   action: pick(Track.MidiInput(source: source, channel: current.channel))))
        }

        let sourceName: String
        let connected: Bool
        switch current.source {
        case .all:
            sourceName = "All"
            connected = true
        case .device(let id):
            let info = inputs.first { $0.uniqueID == id }
            sourceName = info?.name ?? "Source \(id)"
            connected = info?.connected ?? false
            if info == nil {
                // The selection stays; it is shown so it can be seen and picked away from.
                sources.append(.toggle("\(prefix).source.\(id)", "MIDI Input \(sourceName) (not connected)", isOn: true,
                                       action: pick(current)))
            }
        }

        let channels: [UIControl] = (0...Track.MidiInput.maxChannel).map { channel in
            .toggle("\(prefix).channel.\(channel)", "MIDI Channel \(channel == 0 ? "Omni" : String(channel))",
                    isOn: current.channel == channel,
                    action: pick(Track.MidiInput(source: current.source, channel: channel)))
        }
        return TrackMidiInputMenu(input: current, sourceName: sourceName, connected: connected,
                                  sourceControls: sources, channelControls: channels)
    }
}
