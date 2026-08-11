import SwiftUI

/// Shared STT configuration shown from the app settings entry point.
@available(macOS 26.0, iOS 26.0, *)
@MainActor
struct SettingsView: View {
    @AppStorage(SttLocalePreferences.key)
    private var localeIdentifier = SttLocalePreferences.defaultIdentifier
    @AppStorage(SttAppleVersion.key)
    private var sttAppleVersionRawValue = SttAppleVersion.defaultValue.rawValue
    @State private var supportedLocaleTags: [String] = []

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("STT locale", selection: localeBinding) {
                    ForEach(supportedLocaleTags, id: \.self) { tag in
                        Text(localeTitle(for: tag)).tag(tag)
                    }
                }
                .disabled(supportedLocaleTags.isEmpty)

                Picker("Method", selection: sttAppleVersionBinding) {
                    ForEach(SttAppleVersion.allCases) { version in
                        Text(version.title).tag(version.rawValue)
                    }
                }

                Text("Changing locale or method reloads Apple Speech. New uses SpeechAnalyzer; Old uses SFSpeechURLRecognitionRequest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .font(.callout)
        #if os(macOS)
        .frame(width: 440, height: 240)
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

    private func localeTitle(for tag: String) -> String {
        let name = SttAppleLocaleResolver.displayName(for: Locale(identifier: tag))
        return "\(name) (\(tag))"
    }
}
