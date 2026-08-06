#if os(macOS)
import AppKit
#endif
import Darwin
import SwiftUI

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // parakeet, qwen3-tts, and Audio8 each own distinct ggml Metal
        // runtimes. Skip their conflicting static destructors; macOS reclaims
        // process-owned GPU resources after _exit just as it does after normal
        // termination.
        fflush(nil)
        _exit(0)
    }
}
#endif

@main
struct STTSApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var engine = StsEngine()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootTabView(engine: engine)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(engine: engine)
        }
        #else
        WindowGroup {
            RootTabView(engine: engine)
        }
        #endif
    }
}
