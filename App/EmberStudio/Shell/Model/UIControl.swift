import Foundation

/// UI-052: an interactive control as its view model describes it. Views draw it with
/// `ControlButton`/`ControlToggle`, which set `id` as the `accessibilityIdentifier`, and `ui.perform`
/// (CTL-002) runs the same `action`. SwiftUI builds no accessibility tree inside the process, so
/// the descriptors, not the views, are what attach mode clicks.
@MainActor
struct UIControl: Identifiable {
    enum Kind: String, Codable, Sendable {
        case button
        case toggle
    }

    /// `track.<id>.mute`, `transport.play`, `pane.inspector`, …
    let id: String
    let kind: Kind
    let label: String
    /// Toggles only.
    let isOn: Bool?
    let isEnabled: Bool
    /// A button's click, or a toggle's flip.
    let action: @MainActor () -> Void

    static func button(_ id: String, _ label: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) -> UIControl {
        UIControl(id: id, kind: .button, label: label, isOn: nil, isEnabled: enabled, action: action)
    }

    static func toggle(_ id: String, _ label: String, isOn: Bool, enabled: Bool = true,
                       action: @escaping @MainActor () -> Void) -> UIControl {
        UIControl(id: id, kind: .toggle, label: label, isOn: isOn, isEnabled: enabled, action: action)
    }
}

/// What `ui.perform` may do to a control.
enum UIAction: String, CaseIterable, Sendable {
    /// Buttons, and toggles (flip).
    case click
    /// Alias of click.
    case press
    /// Toggles: flip.
    case toggle
    /// Toggles: on (nothing if it already is).
    case on
    /// Toggles: off.
    case off
}
