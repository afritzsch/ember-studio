import DAWControl
import Foundation

extension UIStateDumper {
    /// UI-067 (T-124): the window's browser.
    ///
    ///     {"open", "sidebar": "currentProject" | "samples" | "midiFiles" | "place.<id>",
    ///      "sidebarItems": [{"key", "title", "section", "selected", "missing"}],
    ///      "selection": item id | null, "query", "searching",
    ///      "items": [{"id", "control", "name", "path", "kind" (folder|audio|midi), "depth",
    ///                 "expanded" (folders), "selected", "missing"}] (the first 200 rows),
    ///      "itemCount" (all rows), "moreResults" (a search or scan over 5,000 results),
    ///      "places": [{"id", "name", "path", "missing"}], "controls": [ids]}
    ///
    /// T-126 adds `preview`, T-127 `collections`.
    static func dump(_ browser: BrowserModel, open: Bool) -> JSONValue {
        let rows = browser.rows
        return [
            "open": .bool(open),
            "sidebar": .string(browser.sidebarSelection.key),
            "sidebarItems": .array(browser.sections.flatMap { section in
                section.entries.map { entry in
                    [
                        "key": .string(entry.item.key), "title": .string(entry.title), "section": .string(section.title),
                        "selected": .bool(browser.sidebarSelection == entry.item), "missing": .bool(entry.isMissing),
                    ]
                }
            }),
            "selection": browser.selection.map(JSONValue.string) ?? .null,
            "query": .string(browser.query),
            "searching": .bool(browser.isScanning),
            "items": .array(rows.prefix(BrowserModel.controlRowLimit).map { row in
                var item: [String: JSONValue] = [
                    "id": .string(row.id), "control": .string(BrowserModel.itemControlID(row.id)), "name": .string(row.item.name),
                    "path": .string(row.item.url.path), "kind": .string(row.item.kind.rawValue), "depth": .int(Int64(row.depth)),
                    "selected": .bool(browser.selection == row.id), "missing": .bool(row.isMissing),
                ]
                if row.item.isFolder { item["expanded"] = .bool(row.isExpanded) }
                return .object(item)
            }),
            "itemCount": .int(Int64(rows.count)),
            "moreResults": .bool(browser.showsScan && browser.scanTruncated),
            "places": .array(browser.library.places.map {
                ["id": .string($0.id), "name": .string($0.name), "path": .string($0.url.path), "missing": .bool($0.isMissing)]
            }),
            "controls": .array(browser.controls.map { .string($0.id) }),
        ]
    }
}
