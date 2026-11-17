import SwiftUI

/// UI-041 (T-065): the plugin manager, a strip under the toolbar (in the layout, like the audio
/// settings, so `ui.snapshot` shows it): scan / rescan, the usable plugins and the blocked list with
/// each reason. Every button is a view-model control (UI-052).
struct PluginManagerPanel: View {
    let panel: PluginManagerPanelModel
    let controls: [String: UIControl]

    var body: some View {
        let manager = panel.manager
        let usable = manager.usable
        let blocked = manager.blocked
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Plugins").font(.headline)
                Text(summary(manager, usable: usable.count, blocked: blocked.count))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("prefs.plugins.summary")
                if manager.isScanning {
                    ProgressView().controlSize(.small).accessibilityIdentifier("prefs.plugins.progress")
                }
                Spacer()
                if let scan = controls["prefs.plugins.scan"] { ControlButton(control: scan, face: "Scan") }
                if let rescan = controls["prefs.plugins.rescan"] { ControlButton(control: rescan, face: "Rescan All") }
                if let close = controls["prefs.plugins.close"] {
                    ControlButton(control: close, systemImage: "xmark").labelStyle(.iconOnly)
                }
            }
            if let error = manager.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("prefs.plugins.error")
            }
            HStack(alignment: .top, spacing: 16) {
                list("Available", count: usable.count) {
                    ForEach(usable) { plugin in
                        HStack(spacing: 6) {
                            Text(plugin.name).lineLimit(1)
                            Text(detail(plugin)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityIdentifier("prefs.plugins.available")
                list("Blocked", count: blocked.count) {
                    ForEach(Array(blocked.enumerated()), id: \.element.id) { n, plugin in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(plugin.name).lineLimit(1)
                                Text(plugin.blockedReason ?? "").foregroundStyle(.red).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if let retry = controls["prefs.plugins.blocked.\(n).retry"] { ControlButton(control: retry, face: "Retry") }
                        }
                    }
                    if let all = controls["prefs.plugins.blocked.retry"], !blocked.isEmpty {
                        ControlButton(control: all, face: "Retry All")
                    }
                }
                .accessibilityIdentifier("prefs.plugins.blocked")
            }
            .frame(height: 120)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("prefs.plugins.panel")
    }

    private func summary(_ manager: PluginManagerModel, usable: Int, blocked: Int) -> String {
        var text = "\(usable) available, \(blocked) blocked"
        if manager.isScanning { return text + " · scanning…" }
        if let scan = manager.lastScan {
            text += " · last scan: \(scan.scanned) scanned, \(scan.unchanged) unchanged, \(scan.removed) removed"
        }
        if manager.scannerURL == nil { text += " · scanner missing" }
        return text
    }

    private func detail(_ plugin: ScannedPlugin) -> String {
        let kind = plugin.isInstrument ? "instrument" : "effect"
        let vendor = plugin.vendor.isEmpty ? "" : "\(plugin.vendor) · "
        return "\(vendor)\(plugin.format == .au ? "AU" : "VST3") \(kind)"
    }

    private func list(_ title: String, count: Int, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(count))").font(.subheadline.weight(.semibold))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) { rows() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
