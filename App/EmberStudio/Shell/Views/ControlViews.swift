import SwiftUI

// UI-052: the only place views make buttons and toggles. Each takes a `UIControl` descriptor from a
// view model, so the accessibility identifier, the label, the enabled state and the action are the
// ones `ui.state` reports and `ui.perform` runs. `ShellSourceTests` fails on a raw `Button(` or
// `Toggle(` anywhere else under Views/.

struct ControlButton: View {
    let control: UIControl
    var systemImage: String?

    var body: some View {
        Button(action: control.action) {
            if let systemImage {
                Label(control.label, systemImage: systemImage)
            } else {
                Text(control.label)
            }
        }
        .disabled(!control.isEnabled)
        .accessibilityIdentifier(control.id)
        .help(control.label)
    }
}

struct ControlToggle: View {
    let control: UIControl
    /// Short text on the button face (M, S); the full label is the tooltip and accessibility label.
    var face: String?

    var body: some View {
        Toggle(isOn: Binding(get: { control.isOn ?? false }, set: { _ in control.action() })) {
            Text(face ?? control.label)
        }
        .toggleStyle(.button)
        .disabled(!control.isEnabled)
        .accessibilityIdentifier(control.id)
        .accessibilityLabel(control.label)
        .help(control.label)
    }
}
