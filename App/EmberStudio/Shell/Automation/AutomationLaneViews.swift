import DAWModel
import SwiftUI

/// UI-015 (T-075): the "A" toggle and "+ Lane" menu on a track header (bottom right), from the
/// automation model's controls (UI-052: `track.<id>.automation`, `track.<id>.automation.add.<key>`).
struct AutomationTrackAccessory: View {
    let model: AutomationLanesModel
    let trackID: NodeIDValue

    var body: some View {
        let controls = model.controls.filter { $0.id.hasPrefix("track.\(trackID).automation") }
        HStack(spacing: 2) {
            if let toggle = controls.first(where: { $0.id == "track.\(trackID).automation" }) {
                ControlToggle(control: toggle, face: "A").fixedSize()
            }
            let adds = controls.filter { $0.id.hasPrefix("track.\(trackID).automation.add.") }
            if !adds.isEmpty {
                Menu("+ Lane") {
                    ForEach(adds) { control in ControlButton(control: control) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("track.\(trackID).automation.add.menu")
            }
        }
        .controlSize(.small)
        .padding(4)
    }
}

/// UI-015: the header rows of a track's shown lanes (name, mode menu, add point, remove), each as
/// tall as a canvas row so they line up with the lane rows of the canvas.
struct AutomationLaneHeaders: View {
    let model: AutomationLanesModel
    let trackID: NodeIDValue

    var body: some View {
        ForEach(model.lanes(of: trackID), id: \.lane.id) { row in
            AutomationLaneHeader(row: row, controls: model.laneControls(row))
                .frame(height: ProjectWindowModel.trackHeight - 1)
            Divider()
        }
    }
}

private struct AutomationLaneHeader: View {
    let row: LaneRow
    let controls: [UIControl]

    var body: some View {
        let modes = controls.filter { $0.id.contains(".mode.") }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(.orange)
                Text(row.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let remove = controls.first(where: { $0.id.hasSuffix(".remove") }) {
                    ControlButton(control: remove, systemImage: "xmark").labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            HStack(spacing: 4) {
                Menu(row.lane.mode.rawValue.capitalized) {
                    ForEach(modes) { control in ControlToggle(control: control, face: String(control.id.split(separator: ".").last ?? "")) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("automation.lane.\(row.lane.id).mode.menu")
                if let add = controls.first(where: { $0.id.hasSuffix(".addPoint") }) {
                    ControlButton(control: add, systemImage: "plus.circle").labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: AutomationLanePainter.laneColor))
    }
}
