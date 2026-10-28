/// The attach-only methods (CTL-005), implemented by the app (T-032) and handed to its
/// `Dispatcher`. Without one, `ui.*` fail with `methodNotAvailableInHeadless`.
@MainActor
public protocol ControlUIProvider: AnyObject {
    /// `ui.state`: the UIStateDumper JSON.
    func uiState() async throws -> JSONValue
    /// `ui.snapshot`: writes a PNG and returns `{"pngPath": …}`.
    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue
    /// `ui.perform`: simulates a click or toggle.
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue
}
