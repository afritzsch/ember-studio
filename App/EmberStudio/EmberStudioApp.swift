import DAWControl
import DAWModel
import SwiftUI

// Placeholder from T-001. The app shell is defined by 12-ui.
@main
struct EmberStudioApp: App {
    var body: some Scene {
        WindowGroup("Ember Studio") {
            Text("Ember Studio")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
