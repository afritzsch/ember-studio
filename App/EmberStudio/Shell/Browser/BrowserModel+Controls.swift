import Foundation

/// UI-052, UI-067 (T-124): the browser's control descriptors. The pane draws them and `ui.perform`
/// runs them. Ids:
///   - `browser.search` (text field; `setText` searches),
///   - `browser.sidebar.<currentProject|samples|midiFiles|place.<place>>` (toggles, the shown one on),
///   - `browser.places.add` (Add Folder…), `browser.place.<place>.reveal|remove`, and
///     `browser.place.<place>.locate` while the place is missing,
///   - per row (the first `controlRowLimit` rows): `browser.item.<item>` (selects),
///     `browser.item.<item>.expand` (folders, a toggle), `browser.item.<item>.load` (files: the
///     double-click, onto the selected track at the playhead).
/// `<place>` and `<item>` are `BrowserItem.id(forPath:)` of the path, so they stay the same across
/// refreshes and launches.
extension BrowserModel {
    /// UI-067: `ui.state` lists at most this many rows (and their controls).
    static let controlRowLimit = 200

    static func itemControlID(_ id: String) -> String { "browser.item.\(id)" }

    var controls: [UIControl] {
        var controls: [UIControl] = [
            .textField("browser.search", "Search", text: query) { [weak self] text in
                self?.setQuery(text)
                return true
            },
        ]
        for section in sections {
            for entry in section.entries {
                controls.append(.toggle("browser.sidebar.\(entry.item.key)", entry.title, isOn: sidebarSelection == entry.item) {
                    [weak self] in self?.selectSidebar(entry.item)
                })
            }
        }
        controls.append(.button("browser.places.add", "Add Folder…") { [weak self] in self?.addFolder() })
        for place in library.places {
            let id = place.id
            controls.append(.button("browser.place.\(id).reveal", "Reveal \(place.name) in Finder", enabled: !place.isMissing) {
                [weak self] in self?.revealPlace(id)
            })
            controls.append(.button("browser.place.\(id).remove", "Remove \(place.name)") { [weak self] in self?.removePlace(id) })
            if place.isMissing {
                controls.append(.button("browser.place.\(id).locate", "Locate \(place.name)…") { [weak self] in self?.locatePlace(id) })
            }
        }
        controls += rowControls(rows.prefix(Self.controlRowLimit))
        return controls
    }

    func rowControls(_ rows: some Sequence<BrowserRow>) -> [UIControl] {
        rows.flatMap { row -> [UIControl] in
            let id = row.id
            let base = Self.itemControlID(id)
            var controls: [UIControl] = [.button(base, "Select \(row.item.name)") { [weak self] in self?.select(id) }]
            if row.item.isFolder {
                controls.append(.toggle("\(base).expand", "Expand \(row.item.name)", isOn: row.isExpanded) { [weak self] in
                    self?.toggleExpanded(id)
                })
            } else {
                controls.append(.button("\(base).load", "Load \(row.item.name)", enabled: !row.isMissing) { [weak self] in
                    self?.activate(id)
                })
            }
            return controls
        }
    }
}
