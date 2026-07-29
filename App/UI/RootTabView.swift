import SwiftUI

/// Top-level container splitting the app into three focused tabs, all sharing
/// the single `ConversationEngine` (and its one-turn state machine).
struct RootTabView: View {
    var engine: ConversationEngine

    var body: some View {
        TabView {
            ConversationView(engine: engine)
                .tabItem { Label("stts", systemImage: "bubble.left.and.bubble.right") }
            SttFileView(engine: engine)
                .tabItem { Label("stt", systemImage: "waveform") }
            TtsView(engine: engine)
                .tabItem { Label("tts", systemImage: "speaker.wave.2") }
            #if os(iOS)
            // macOS reaches SettingsView through the app's Settings scene
            // (Cmd-,); iOS has no such scene, so it needs its own tab.
            SettingsView(engine: engine)
                .tabItem { Label("settings", systemImage: "gearshape") }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}

#Preview {
    RootTabView(engine: ConversationEngine())
}
