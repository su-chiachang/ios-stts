import SwiftUI

/// Top-level container splitting the app into focused tabs.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
struct RootTabView: View {
    @State private var selectedTab: Tab = .stt
    @State private var showingSettings = false

    private enum Tab { case stt, tts, ttt }

    var body: some View {
        TabView(selection: $selectedTab) {
            SttView()
                .tabItem { Label("stt", systemImage: "waveform") }
                .tag(Tab.stt)
            TtsView()
                .tabItem { Label("tts", systemImage: "speaker.wave.2") }
                .tag(Tab.tts)
            TttView()
                .tabItem { Label("ttt", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Tab.ttt)
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
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
    }
}
