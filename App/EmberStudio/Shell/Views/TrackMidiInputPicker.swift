import SwiftUI

/// T-093 (DW-216): a MIDI track's input menu, for its header and its mixer strip. Sources, then
/// channels; every entry is one of the header's view-model toggles (UI-052), so `ui.perform` and a
/// click do the same thing.
struct TrackMidiInputPicker: View {
    let menu: TrackMidiInputMenu

    var body: some View {
        Menu(menu.title) {
            Section("Source") {
                ForEach(menu.sourceControls) { control in
                    ControlToggle(control: control, face: control.label.replacingOccurrences(of: "MIDI Input ", with: ""))
                }
            }
            Section("Channel") {
                ForEach(menu.channelControls) { control in
                    ControlToggle(control: control, face: control.label.replacingOccurrences(of: "MIDI Channel ", with: ""))
                }
            }
        }
        .help(menu.connected ? "MIDI input" : "MIDI input: \(menu.sourceName) is not connected")
    }
}
