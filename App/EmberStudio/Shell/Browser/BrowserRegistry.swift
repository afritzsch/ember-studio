import Foundation

/// T-124: each window's `BrowserModel`. `AppModel` registers a window with the app's library when
/// it makes it, and forgets it when it closes. A window made without the app (tests) gets a
/// browser over an in-memory library the first time it asks.
@MainActor
enum BrowserRegistry {
    private static var models: [ObjectIdentifier: BrowserModel] = [:]

    /// The browser of `window`, made on first use.
    static func model(for window: ProjectWindowModel, library: @autoclosure () -> BrowserLibrary? = nil) -> BrowserModel {
        let key = ObjectIdentifier(window)
        // A window that went away without `remove` may have left its key to a new window.
        if let model = models[key], model.window === window { return model }
        let model = BrowserModel(window: window, library: library() ?? BrowserLibrary(settingsURL: nil))
        models[key] = model
        return model
    }

    /// `AppModel.addWindow`: the window's browser uses `library` (the app's).
    @discardableResult
    static func register(_ window: ProjectWindowModel, library: BrowserLibrary) -> BrowserModel {
        let model = BrowserModel(window: window, library: library)
        models[ObjectIdentifier(window)] = model
        return model
    }

    /// `AppModel.closeWindow`.
    static func remove(_ window: ProjectWindowModel) {
        if let model = models.removeValue(forKey: ObjectIdentifier(window)) { model.library.removeListener(model) }
        models = models.filter { $0.value.window != nil }
    }
}

extension ProjectWindowModel {
    /// UI-060 (T-124): this window's browser.
    var browser: BrowserModel { BrowserRegistry.model(for: self) }
}
