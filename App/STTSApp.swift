#if os(macOS)
import AppKit
#endif
import SwiftUI

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
