import AppKit
import Darwin
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // parakeet and qwen3-tts each own a distinct ggml Metal runtime. Skip
        // their conflicting static destructors; macOS reclaims process-owned
        // GPU resources after _exit just as it does after normal termination.
        fflush(nil)
        _exit(0)
    }
}

@main
struct STTSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
