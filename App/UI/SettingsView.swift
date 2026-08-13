import SwiftUI

/// Shared STT configuration shown from the app settings entry point.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
struct SettingsView: View {
    @AppStorage(SttLocalePreferences.key)
    private var localeIdentifier = SttLocalePreferences.defaultIdentifier
    @AppStorage(SttAppleVersion.key)
    private var sttAppleVersionRawValue = SttAppleVersion.defaultValue.rawValue
    @AppStorage(SttAppleNewType.key)
    private var sttAppleNewTypeRawValue = SttAppleNewType.defaultValue.rawValue
    @AppStorage(SttAppleOldType.key)
    private var sttAppleOldTypeRawValue = SttAppleOldType.defaultValue.rawValue
    @AppStorage(SttAppleNewFilePreset.key)
    private var sttFilePresetRawValue = SttAppleNewFilePreset.defaultValue.rawValue
    @AppStorage(SttAppleNewLivePreset.key)
    private var sttLivePresetRawValue = SttAppleNewLivePreset.defaultValue.rawValue
    @State private var supportedLocaleTags: [String] = []

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Version", selection: sttAppleVersionBinding) {
                    ForEach(SttAppleVersion.allCases) { version in
                        Text(version.rawValue)
                    }
                }

                Picker("Locale", selection: sttLocaleBinding) {
                    ForEach(supportedLocaleTags, id: \.self) { tag in
                        Text(localeTitle(for: tag)).tag(tag)
                    }
                }
                .disabled(supportedLocaleTags.isEmpty)

                Picker("Type", selection: sttTypeBinding) {
                    switch SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue) {
                    case .new:
                        ForEach(SttAppleNewType.allCases) { type in
                            Text(type.rawValue).tag(type.rawValue)
                        }
                    case .old:
                        ForEach(SttAppleOldType.allCases) { type in
                            Text(type.rawValue).tag(type.rawValue)
                        }
                    }
                }

                Picker("Preset", selection: sttPresetBinding) {
                    switch SttAppleNewType.resolve(rawValue: sttAppleNewTypeRawValue) {
                    case .file:
                        ForEach(SttAppleNewFilePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset.rawValue)
                        }
                    case .live:
                        ForEach(SttAppleNewLivePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset.rawValue)
                        }
                    }
                }
                .disabled(SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue) != .new)

                Text("New uses SpeechTranscriber for File and DictationTranscriber for Live. Old uses SFSpeechURLRecognitionRequest for File and SFSpeechAudioBufferRecognitionRequest for Live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .font(.callout)
        #if os(macOS)
        .frame(width: 440, height: 300)
        #endif
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

    private var sttLocaleBinding: Binding<String> {
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

    private var sttTypeBinding: Binding<String> {
        switch SttAppleVersion.resolve(rawValue: sttAppleVersionRawValue) {
        case .new:
            Binding(
                get: { SttAppleNewType.resolve(rawValue: sttAppleNewTypeRawValue).rawValue },
                set: { newValue in
                    sttAppleNewTypeRawValue = SttAppleNewType.resolve(rawValue: newValue).rawValue
                })
        case .old:
            Binding(
                get: { SttAppleOldType.resolve(rawValue: sttAppleOldTypeRawValue).rawValue },
                set: { newValue in
                    sttAppleOldTypeRawValue = SttAppleOldType.resolve(rawValue: newValue).rawValue
                })
        }
    }

    private var sttPresetBinding: Binding<String> {
        switch SttAppleNewType.resolve(rawValue: sttAppleNewTypeRawValue) {
        case .file:
            Binding(
                get: { SttAppleNewFilePreset.resolve(rawValue: sttFilePresetRawValue).rawValue },
                set: { newValue in
                    sttFilePresetRawValue = SttAppleNewFilePreset.resolve(rawValue: newValue).rawValue
                })
        case .live:
            Binding(
                get: { SttAppleNewLivePreset.resolve(rawValue: sttLivePresetRawValue).rawValue },
                set: { newValue in
                    sttLivePresetRawValue = SttAppleNewLivePreset.resolve(rawValue: newValue).rawValue
                })
        }
    }

    private func localeTitle(for tag: String) -> String {
        let name = SttAppleLocaleResolver.displayName(for: Locale(identifier: tag))
        return "\(name) (\(tag))"
    }
}
