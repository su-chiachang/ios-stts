import SwiftUI

/// Top-level container splitting the app into three focused tabs, all sharing
/// the single `ConversationEngine` (and its one-turn state machine).
struct RootTabView: View {
    var engine: ConversationEngine
    @State private var selectedTab: Tab = .stt

    private enum Tab { case stt, tts, stts, settings }

    var body: some View {
        TabView(selection: $selectedTab) {
            SttFileView(engine: engine)
                .tabItem { Label("stt", systemImage: "waveform") }
                .tag(Tab.stt)
            TtsView(engine: engine)
                .tabItem { Label("tts", systemImage: "speaker.wave.2") }
                .tag(Tab.tts)
            ConversationView(engine: engine)
                .tabItem { Label("stts", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.stts)
            #if os(iOS)
            // macOS reaches SettingsView through the app's Settings scene
            // (Cmd-,); iOS has no such scene, so it needs its own tab.
            SettingsView(engine: engine)
                .tabItem { Label("settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        // Each tab only keeps its own model(s) resident — loading STT and
        // TTS together pushed memory past the OS jetsam limit on-device.
        // Settings needs neither directly, so switching to it leaves
        // whatever's already loaded untouched rather than unloading it.
        .task(id: selectedTab) {
            switch selectedTab {
            case .stt: await engine.activate(.stt)
            case .tts: await engine.activate(.tts)
            case .stts: await engine.activate(.both)
            case .settings: break
            }
        }
    }
}

#Preview {
    RootTabView(engine: ConversationEngine())
}
