/// DW-336 (T-112, 07 "Contract delta (T-112)"): who opened a gesture (MODEL-003). Only commands
/// performed by a gesture's owner join it; a command from anyone else while it is open is its own
/// undo entry with its own label, and doesn't end the gesture. Each owner has at most one gesture
/// open (nesting within an owner works as before), so a plugin editor's knob drag and a UI fader
/// drag are two entries even when they overlap.
///
/// The App's `beginGesture`/`endGesture`/`perform` calls use `.ui`, the default, unchanged.
public enum GestureOwner: Hashable, Sendable {
    /// The app's own controls (drags in the arrange, mixer, piano roll, device chain). The default.
    case ui
    /// A hosted plugin's own editor (`PluginEditRecorder`, AutomationRecorder's plugin path).
    case pluginEditor
    /// A finished recording being imported (`ProjectStore.importRecording`).
    case recording
    /// Automation passes (`AutomationRecorder`). It never opens a gesture, so each committed pass
    /// is its own undo entry.
    case automation
    /// The control protocol (`Dispatcher`: headless and attach-mode commands).
    case control
    /// Any other source that needs its own gestures (a tool, a test).
    case token(UInt64)
}
