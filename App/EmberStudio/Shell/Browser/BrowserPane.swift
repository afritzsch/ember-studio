import AppKit
import SwiftUI

/// UI-060 (T-124): the browser pane, thin over `BrowserModel` (UI-003). A search field on top,
/// then two columns: the sidebar (Categories, Places) and the content list (a tree with
/// disclosure for folders). ↑/↓ select, ←/→ collapse/expand, Return or a double-click loads;
/// files drag onto the arrange view (UI-063). T-126 adds the preview footer under the list.
struct BrowserPane: View {
    let model: BrowserModel

    var body: some View {
        let controls = Dictionary(model.controls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            BrowserSearchField(model: model)
                .padding(6)
            Divider()
            HStack(spacing: 0) {
                BrowserSidebar(model: model, controls: controls)
                    .frame(width: 118)
                Divider()
                BrowserContent(model: model, controls: controls)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("browser.pane")
        .onAppear { model.refresh() }
    }
}

private struct BrowserSearchField: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // UI-062: every keystroke searches (the last search is cancelled).
            TextField("Search", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("browser.search")
                .onExitCommand { model.setQuery("") }
            if model.isScanning {
                ProgressView().controlSize(.mini)
            } else if !model.query.isEmpty {
                Button { model.setQuery("") } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
    }
}

private struct BrowserSidebar: View {
    let model: BrowserModel
    let controls: [String: UIControl]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.sections) { section in
                    HStack {
                        Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if section.title == "Places", let add = controls["browser.places.add"] {
                            Button(action: add.action) { Image(systemName: "plus") }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help(add.label)
                                .accessibilityIdentifier(add.id)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
                    ForEach(section.entries) { entry in
                        SidebarRow(model: model, entry: entry, controls: controls)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct SidebarRow: View {
    let model: BrowserModel
    let entry: BrowserSidebarSection.Entry
    let controls: [String: UIControl]

    private var selected: Bool { model.sidebarSelection == entry.item }

    private var icon: String {
        switch entry.item {
        case .currentProject: "music.note.house"
        case .category(.samples): "waveform"
        case .category(.midiFiles): "pianokeys"
        case .place: entry.isMissing ? "questionmark.folder" : "folder"
        }
    }

    var body: some View {
        Button { model.selectSidebar(entry.item) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).frame(width: 14)
                Text(entry.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .foregroundStyle(entry.isMissing ? .secondary : .primary)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("browser.sidebar.\(entry.item.key)")
        .help(entry.isMissing ? "\(entry.title) (not found)" : entry.title)
        .contextMenu {
            if case .place(let id) = entry.item {
                if let locate = controls["browser.place.\(id).locate"] { Button(locate.label, action: locate.action) }
                if let reveal = controls["browser.place.\(id).reveal"] {
                    Button("Reveal in Finder", action: reveal.action).disabled(!reveal.isEnabled)
                }
                if let remove = controls["browser.place.\(id).remove"] { Button("Remove", action: remove.action) }
            }
        }
    }
}

private struct BrowserContent: View {
    let model: BrowserModel
    let controls: [String: UIControl]

    var body: some View {
        let rows = model.rows
        if let place = model.selectedPlace, place.isMissing, !model.showsScan {
            VStack(spacing: 6) {
                Text("\(place.name) wasn't found").font(.callout)
                HStack {
                    if let locate = controls["browser.place.\(place.id).locate"] { ControlButton(control: locate, face: "Locate…") }
                    if let remove = controls["browser.place.\(place.id).remove"] { ControlButton(control: remove, face: "Remove") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(rows) { row in
                    BrowserRowView(model: model, row: row).tag(row.id)
                }
                if model.scanTruncated {
                    Text("More results — refine the search")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .accessibilityIdentifier("browser.moreResults")
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 18)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Reveal in Finder") { model.revealItem(id) }
                }
            } primaryAction: { ids in
                // UI-060: Return or a double-click loads (a folder opens or closes).
                if let id = ids.first { model.activate(id) }
            }
            .onKeyPress(.leftArrow) {
                model.collapseSelection()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.expandSelection()
                return .handled
            }
            .accessibilityIdentifier("browser.list")
        }
    }

    private var emptyText: String {
        if model.isScanning { return "Searching…" }
        if model.showsScan { return model.query.isEmpty ? "No files in your places" : "Nothing matches “\(model.query)”" }
        switch model.sidebarSelection {
        case .currentProject: return "No audio in this project yet"
        case .place: return "Empty folder"
        case .category: return ""
        }
    }
}

private struct BrowserRowView: View {
    let model: BrowserModel
    let row: BrowserRow

    var body: some View {
        HStack(spacing: 3) {
            Spacer().frame(width: CGFloat(row.depth) * 12)
            if row.item.isFolder {
                Button { model.toggleExpanded(row.id) } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right").font(.caption2)
                }
                .buttonStyle(.plain)
                .frame(width: 10)
                .accessibilityIdentifier("\(BrowserModel.itemControlID(row.id)).expand")
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
            Text(row.item.name).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(row.isMissing ? .secondary : .primary)
        .help(row.isMissing ? "\(row.item.url.path) (missing)" : row.item.url.path)
        .accessibilityIdentifier(BrowserModel.itemControlID(row.id))
        .onDrag {
            // UI-063: files drag onto the arrange view as file URLs (as from Finder).
            row.item.isFolder ? NSItemProvider() : NSItemProvider(object: row.item.url as NSURL)
        }
    }

    private var icon: String {
        switch row.item.kind {
        case .folder: "folder"
        case .audio: "waveform"
        case .midi: "pianokeys"
        }
    }
}
