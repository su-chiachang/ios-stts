import SwiftUI

/// Shared speech configuration shown from the app settings entry point.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
struct SettingsView: View {
    @AppStorage(SttLocalePreferences.key)
    private var localeIdentifier = SttLocalePreferences.defaultIdentifier
    @AppStorage(SttAppleVersion.key)
    private var sttAppleVersionRawValue = SttAppleVersion.defaultValue.rawValue
    @AppStorage(SttInputType.key)
    private var sttInputTypeRawValue = SttInputType.defaultValue.rawValue
    @AppStorage(AppleTtsVoicePreferences.key)
    private var selectedVoiceIdentifier = ""
    @State private var supportedLocaleTags: [String] = []
    @StateObject private var voiceCatalogStore: AppleTtsVoiceCatalogStore

    init(
        voiceCatalog: AppleTtsVoiceCatalog = AppleTtsVoiceCatalog(),
        voiceChangeNotifications: NotificationCenter = .default
    ) {
        _voiceCatalogStore = StateObject(
            wrappedValue: AppleTtsVoiceCatalogStore(
                catalog: voiceCatalog,
                notificationCenter: voiceChangeNotifications))
    }

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Locale", selection: localeBinding) {
                    ForEach(supportedLocaleTags, id: \.self) { tag in
                        Text(localeTitle(for: tag)).tag(tag)
                    }
                }
                .disabled(supportedLocaleTags.isEmpty)

                Picker("Version", selection: sttAppleVersionBinding) {
                    ForEach(SttAppleVersion.allCases) { version in
                        Text(version.rawValue)
                    }
                }

                Picker("Type", selection: sttInputTypeBinding) {
                    ForEach(SttInputType.allCases) { inputType in
                        Text(inputType.rawValue)
                    }
                }

                Text("New uses SpeechTranscriber for File and DictationTranscriber for Live. Old uses SFSpeechURLRecognitionRequest for File and SFSpeechAudioBufferRecognitionRequest for Live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Speech synthesis") {
                Menu {
                    Button {
                        selectedVoiceIdentifier = ""
                    } label: {
                        Label(
                            "Automatic (language matched)",
                            systemImage: selectedVoiceIdentifier.isEmpty ? "checkmark" : "circle")
                    }

                    if !voiceCatalogStore.groups.isEmpty {
                        Divider()
                        ForEach(voiceCatalogStore.groups) { group in
                            Menu("\(group.languageName) (\(group.language))") {
                                ForEach(group.voices) { voice in
                                    Button {
                                        selectedVoiceIdentifier = voice.identifier
                                    } label: {
                                        Label(
                                            "\(voice.name) · \(voice.quality.title)",
                                            systemImage: selectedVoiceIdentifier == voice.identifier ? "checkmark" : "circle")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(voiceSelectionTitle, systemImage: "chevron.up.chevron.down")
                }
                .disabled(voiceCatalogStore.groups.isEmpty)

                if voiceCatalogStore.groups.isEmpty {
                    Text("No system voices are currently available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .font(.callout)
        #if os(macOS)
        .frame(width: 440, height: 300)
        #endif
        .onAppear {
            voiceCatalogStore.refresh()
            voiceCatalogStore.startObserving()
        }
        .onDisappear { voiceCatalogStore.stopObserving() }
        .task(id: sttAppleVersionRawValue) { await loadSupportedLocales() }
    }

    private func loadSupportedLocales() async {
        let version = SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue)
        let locales = await SttAppleLocaleResolver.supportedLocales(for: version)
        guard !Task.isCancelled else { return }
        let tags = locales.map(SttAppleLocaleResolver.tag(for:))
        supportedLocaleTags = tags

        guard !tags.isEmpty,
              !tags.contains(where: { $0.caseInsensitiveCompare(SttAppleLocaleResolver.tag(for: localeIdentifier)) == .orderedSame })
        else { return }

        let systemTag = SttAppleLocaleResolver.tag(for: Locale.current)
        let fallback = tags.first(where: { $0.caseInsensitiveCompare(systemTag) == .orderedSame }) ?? tags[0]
        localeIdentifier = fallback
        SttLocalePreferences.save(fallback)
    }

    private var localeBinding: Binding<String> {
        Binding(
            get: { SttAppleLocaleResolver.tag(for: localeIdentifier) },
            set: { newValue in
                let canonical = SttAppleLocaleResolver.tag(for: newValue)
                guard canonical != SttAppleLocaleResolver.tag(for: localeIdentifier) else { return }
                localeIdentifier = canonical
                SttLocalePreferences.save(canonical)
            })
    }

    private var sttAppleVersionBinding: Binding<String> {
        Binding(
            get: { SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue).rawValue },
            set: { newValue in
                sttAppleVersionRawValue = SttAppleVersion.resolve(rawValue: newValue).rawValue
            })
    }

    private var sttInputTypeBinding: Binding<String> {
        Binding(
            get: { SttInputType.resolve(rawValue: sttInputTypeRawValue).rawValue },
            set: { newValue in
                sttInputTypeRawValue = SttInputType.resolve(rawValue: newValue).rawValue
            })
    }

    private func localeTitle(for tag: String) -> String {
        let name = SttAppleLocaleResolver.displayName(for: Locale(identifier: tag))
        return "\(name) (\(tag))"
    }

    private var voiceSelectionTitle: String {
        guard let selectedVoice = voiceCatalogStore.groups
            .flatMap(\.voices)
            .first(where: { $0.identifier == selectedVoiceIdentifier })
        else {
            return "Automatic voice"
        }
        return "Voice: \(selectedVoice.name)"
    }
}
