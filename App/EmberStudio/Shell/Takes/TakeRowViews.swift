import DAWModel
import SwiftUI

/// UI-016 (T-081): the header rows of a track's take rows (expanded take folders), each as tall as
/// a canvas row so they line up with the take rows of the canvas. A row names its take, marks it
/// when the comp plays it somewhere, and offers "Use" (the take for the whole folder); a folder's
/// first row also holds its disclosure (hide the takes) and "delete folder". Every control is the
/// take model's (UI-052).
struct TakeRowHeaders: View {
    let model: TakeFoldersModel
    let trackID: NodeIDValue

    var body: some View {
        let rows = model.rows(of: trackID)
        ForEach(rows, id: \.take.id) { row in
            TakeRowHeader(row: row, folder: model.window?.project.takeFolder(row.folderID), controls: controls(row))
                .frame(height: ProjectWindowModel.trackHeight - 1)
            Divider()
        }
    }

    private func controls(_ row: TakeRow) -> [UIControl] {
        guard let folder = model.window?.project.takeFolder(row.folderID) else { return [] }
        let name = model.window?.project.track(row.trackID)?.name ?? ""
        return model.folderControls(folder, trackName: name).filter {
            $0.id == "takeFolder.\(row.folderID).take.\(row.take.id).select"
                || (row.number == 1 && ($0.id == "takeFolder.\(row.folderID).expand" || $0.id == "takeFolder.\(row.folderID).remove"))
        }
    }
}

private struct TakeRowHeader: View {
    let row: TakeRow
    let folder: TakeFolder?
    let controls: [UIControl]

    var body: some View {
        let inComp = folder?.comp.contains { $0.take == row.take.id } ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let expand = controls.first(where: { $0.id.hasSuffix(".expand") }) {
                    ControlButton(control: expand, systemImage: "chevron.down").labelStyle(.iconOnly).buttonStyle(.borderless)
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
                Image(systemName: inComp ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundStyle(inComp ? Color(nsColor: TakeFolderPainter.folderColor) : .secondary)
                    .help(inComp ? "The comp plays this take" : "Not in the comp")
                Text("Take \(row.number)")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let remove = controls.first(where: { $0.id.hasSuffix(".remove") }) {
                    ControlButton(control: remove, systemImage: "trash").labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            HStack(spacing: 4) {
                if let use = controls.first(where: { $0.id.hasSuffix(".select") }) {
                    ControlButton(control: use, face: "Use for Folder")
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: TakeFolderPainter.takeRowColor))
    }
}
