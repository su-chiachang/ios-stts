import SwiftUI

@main
struct STTSApp: App {
    @State private var engine = ConversationEngine()

    var body: some Scene {
        WindowGroup {
            ConversationView(engine: engine)
                .task { await engine.loadModels() }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(engine: engine)
        }
    }
}
