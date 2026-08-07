import SwiftUI

/// Top-level container splitting the app into four focused tabs, all sharing
/// the single STS engine and its one-turn state machine.
struct RootTabView: View {
    var engine: StsEngine
    @State private var selectedTab: Tab = .stt
    @State private var showingSettings = false

    private enum Tab { case stt, tts, ttt, sts }

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
        }
        // Each tab only keeps its own Apple model resident. The STS tab is the
        // one exception because a spoken turn needs both speech services.
        .task(id: selectedTab) {
            switch selectedTab {
            case .stt: await engine.activate(.stt)
            case .tts: await engine.activate(.tts)
            case .sts: await engine.activate(.both)
            case .ttt: break
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(engine: engine)
        }
    }
}

#Preview {
    RootTabView(engine: StsEngine())
}
