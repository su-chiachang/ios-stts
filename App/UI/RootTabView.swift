import SwiftUI

/// Top-level container splitting the app into three focused tabs, all sharing
/// the single `ConversationEngine` (and its one-turn state machine).
struct RootTabView: View {
    var engine: StsEngine
    @State private var selectedTab: Tab = .stt

    private enum Tab { case stt, tts, ttt, sts, settings }

    var body: some View {
        TabView(selection: $selectedTab) {
            SttView(engine: engine)
                .tabItem { Label("stt", systemImage: "waveform") }
                .tag(Tab.stt)
            TtsView(engine: engine)
                .tabItem { Label("tts", systemImage: "speaker.wave.2") }
                .tag(Tab.tts)
            TttView()
                .tabItem { Label("ttt", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Tab.ttt)
            StsView(engine: engine)
                .tabItem { Label("sts", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.sts)
            #if os(iOS)
            // macOS reaches SettingsView through the app's Settings scene
            // (Cmd-,); iOS has no such scene, so it needs its own tab.
            SettingsView(engine: engine)
                .tabItem { Label("settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            #endif
        }
        // Each tab only keeps its own model(s) resident — loading STT and
        // TTS together pushed memory past the OS jetsam limit on-device.
        // Settings needs neither directly, so switching to it leaves
        // whatever's already loaded untouched rather than unloading it.
        .task(id: selectedTab) {
            switch selectedTab {
            case .stt: await engine.activate(.stt)
            case .tts: await engine.activate(.tts)
            case .sts: await engine.activate(.both)
            case .ttt, .settings: break
            }
        }
    }
}

#Preview {
    RootTabView(engine: StsEngine())
}
