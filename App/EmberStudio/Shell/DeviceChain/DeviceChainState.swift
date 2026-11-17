import DAWControl
import DAWModel
import Foundation

/// UI-050 (T-065): `ui.state` for the Device Chain tab (UI-032), the plugin manager (UI-041) and
/// the mixer's editable inserts (DW-250).
extension UIStateDumper {
    /// `{open, channel, channelName, channels[{id, name}], gesture: {slot, index} | null, safeMode,
    ///   choices[{key, name, group}], devices[{id, name, format, instrument, position, bypass,
    ///   safeModeBypassed, plugin, loaded, loadError, editorOpen, noEditor, showsParams,
    ///   acceptsSidechain, sidechain{source, name} | null, params[{index, id, name, unit, min, max,
    ///   curve, steps, labels, style, value, display, position, set, automated, automatable}],
    ///   controls}]}`
    static func dump(_ chain: DeviceChainModel) -> JSONValue {
        [
            "open": .bool(chain.isOpen),
            "channel": .int(Int64(bitPattern: chain.channelID)),
            "channelName": .string(chain.channelName(chain.channelID)),
            "channels": .array(chain.channelChoices.map { ["id": .int(Int64(bitPattern: $0.id)), "name": .string($0.name)] }),
            "gesture": chain.activeDrag.map { ["slot": .int(Int64(bitPattern: $0.slot)), "index": .int(Int64($0.index))] } ?? .null,
            "safeMode": .bool(chain.window?.store.isSafeMode ?? false),
            "choices": .array(chain.choices.map { ["key": .string($0.key), "name": .string($0.name), "group": .string($0.group.rawValue)] }),
            "devices": .array(chain.devices.map(dump)),
        ]
    }

    private static func dump(_ card: DeviceCardModel) -> JSONValue {
        [
            "id": .int(Int64(bitPattern: card.id)), "name": .string(card.name), "format": .string(card.format),
            "instrument": .bool(card.isInstrument), "position": card.position.map { .int(Int64($0)) } ?? .null,
            "bypass": .bool(card.bypass), "safeModeBypassed": .bool(card.safeModeBypassed), "plugin": .bool(card.isPlugin),
            "loaded": card.loaded.map(JSONValue.bool) ?? .null, "loadError": card.loadError.map(JSONValue.string) ?? .null,
            "disabled": .bool(card.disabled),
            "editorOpen": .bool(card.editorOpen), "noEditor": .bool(card.noEditor), "showsParams": .bool(card.showsParams),
            "acceptsSidechain": .bool(card.acceptsSidechain),
            "sidechain": card.sidechain.map { ["source": .int(Int64(bitPattern: $0.source)), "name": .string($0.name)] } ?? .null,
            "params": .array(card.params.map(dump)),
            "controls": .array(card.controls.map { .string($0.id) }),
        ]
    }

    private static func dump(_ param: DeviceParamModel) -> JSONValue {
        let row = param.row
        return [
            "index": .int(Int64(row.index)), "id": .string(row.id), "name": .string(row.name), "unit": .string(row.unit),
            "min": .double(Double(row.min)), "max": .double(Double(row.max)), "curve": .string(row.curve.rawValue),
            "steps": .int(Int64(row.steps)), "labels": row.labels.map { .array($0.map(JSONValue.string)) } ?? .null,
            "style": .string(param.style), "value": number(param.value), "display": .string(param.display),
            "position": .double(param.position), "set": .bool(param.isSet), "automated": .bool(param.automated),
            "automatable": .bool(row.automatable),
        ]
    }

    /// `{open, scanning, loaded, cachePath, scannerPath | null, lastScan{scanned, unchanged, removed} | null,
    ///   error | null, plugins[{format, identifier, name, vendor, version, instrument, sidechain, numParams}],
    ///   blocked[{n, format, identifier, name, reason, timedOut}]}` (`timedOut`: T-094, DW-275)
    static func dump(_ panel: PluginManagerPanelModel) -> JSONValue {
        let manager = panel.manager
        let open = panel.isOpen
        return [
            "open": .bool(open),
            "scanning": .bool(manager.isScanning),
            "loaded": .bool(manager.isLoaded),
            "cachePath": .string(manager.cacheURL.path),
            "scannerPath": manager.scannerURL.map { .string($0.path) } ?? .null,
            "lastScan": manager.lastScan.map { scan in
                ["scanned": .int(Int64(scan.scanned)), "unchanged": .int(Int64(scan.unchanged)), "removed": .int(Int64(scan.removed))]
            } ?? .null,
            "error": manager.error.map(JSONValue.string) ?? .null,
            // Listed once the panel was opened or a picker needed them (the cache is read lazily).
            "plugins": .array(manager.isLoaded ? manager.usable.map(dump) : []),
            "blocked": .array(manager.isLoaded ? manager.blocked.enumerated().map { n, plugin in
                ["n": .int(Int64(n)), "format": .string(plugin.format.rawValue), "identifier": .string(plugin.identifier),
                 "name": .string(plugin.name), "reason": .string(plugin.blockedReason ?? ""), "timedOut": .bool(plugin.isTimedOut)]
            } : []),
        ]
    }

    private static func dump(_ plugin: ScannedPlugin) -> JSONValue {
        [
            "format": .string(plugin.format.rawValue), "identifier": .string(plugin.identifier), "name": .string(plugin.name),
            "vendor": .string(plugin.vendor), "version": .string(plugin.version), "instrument": .bool(plugin.isInstrument),
            "sidechain": .bool(plugin.hasSidechain), "numParams": .int(Int64(plugin.numParams)),
        ]
    }

    /// DW-250 (T-065): a mixer strip's inserts: `[{id, name, bypass, safeModeBypassed, format, plugin,
    /// editorOpen}]`.
    static func mixerInserts(_ strip: MixerStripModel) -> JSONValue {
        .array(strip.inserts.map { insert in
            [
                "id": .int(Int64(bitPattern: insert.id)), "name": .string(insert.name), "bypass": .bool(insert.bypass),
                "safeModeBypassed": .bool(insert.safeModeBypassed), "format": .string(insert.format),
                "plugin": .bool(insert.isPlugin), "editorOpen": .bool(insert.editorOpen),
            ]
        })
    }

    private static func number(_ value: Float) -> JSONValue {
        value.isFinite ? .double(Double(value)) : .null
    }
}
