import SwiftUI

// UI-052: the only place views make buttons and toggles. Each takes a `UIControl` descriptor from a
// view model, so the accessibility identifier, the label, the enabled state and the action are the
// ones `ui.state` reports and `ui.perform` runs. `ShellSourceTests` fails on a raw `Button(` or
// `Toggle(` anywhere else under Views/.

struct ControlButton: View {
    let control: UIControl
    var systemImage: String?
    /// Text on the button face when it differs from the label (a track's name on its select button).
    var face: String?

    var body: some View {
        Button(action: control.action) {
            if let systemImage {
                Label(face ?? control.label, systemImage: systemImage)
            } else {
                Text(face ?? control.label)
            }
        }
        .disabled(!control.isEnabled)
        .accessibilityIdentifier(control.id)
        .accessibilityLabel(control.label)
        .help(control.label)
    }
}

struct ControlToggle: View {
    let control: UIControl
    /// Short text on the button face (M, S); the full label is the tooltip and accessibility label.
    var face: String?
    /// A checkbox instead of a button (settings in a dialog, T-082, where on and off must read apart).
    var checkbox = false

    var body: some View {
        styled(Toggle(isOn: Binding(get: { control.isOn ?? false }, set: { _ in control.action() })) {
            Text(face ?? control.label)
        })
        .disabled(!control.isEnabled)
        .accessibilityIdentifier(control.id)
        .accessibilityLabel(control.label)
        .help(control.label)
    }

    @ViewBuilder
    private func styled(_ toggle: some View) -> some View {
        if checkbox {
            toggle.toggleStyle(.checkbox)
        } else {
            toggle.toggleStyle(.button)
        }
    }
}

/// DW-180 (T-095): a text field that edits a value on commit (Return or leaving the field), not per
/// keystroke, so one commit is one undo entry. `commit` returns false for input it refuses; the field
/// then shows `value` again, as it does whenever it isn't being edited. Escape reverts.
struct CommitTextField: View {
    /// The accessibility identifier (names the view; `ui.perform` can't type, 12).
    let id: String
    let label: String
    /// The model's value as text.
    let value: String
    let commit: @MainActor (String) -> Bool
    var width: CGFloat = 60

    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .frame(width: width)
            .focused($focused)
            .onSubmit { finish() }
            .onExitCommand {
                text = value
                editing = false
                focused = false
            }
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !editing { text = new } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { editing = true } else if editing { finish() }
            }
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .help(label)
    }

    private func finish() {
        editing = false
        if text != value { _ = commit(text) }
        text = value  // the committed value as the project now has it, or the old one (refused)
    }
}
