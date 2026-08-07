import SwiftUI

/// The small amount of user configuration that remains: Apple's STT locale.
/// Model, backend, download, and custom-voice settings are intentionally gone.
struct SettingsView: View {
    var engine: StsEngine

    @AppStorage(SttLocalePreferences.key)
    private var sttLocale = SttLocalePreferences.defaultIdentifier
    @State private var supportedLocaleTags: [String] = []
    @State private var isReloading = false

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("STT locale", selection: localeBinding) {
                    Text("Auto (system locale)")
                        .tag(AppleSpeechLocaleResolver.autoTag)

                    ForEach(localeOptions, id: \.self) { tag in
                        Text(localeTitle(for: tag)).tag(tag)
                    }
                }
                .disabled(isReloading || engine.state == .loadingModels)

                if isReloading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Preparing the selected Apple Speech locale…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Auto uses the current system locale. Changing this value reloads Apple Speech when STT is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .font(.callout)
        #if os(macOS)
        .frame(width: 440, height: 220)
        #endif
        .task {
            guard supportedLocaleTags.isEmpty else { return }
            let locales = await AppleSpeechLocaleResolver.supportedLocales()
            supportedLocaleTags = locales.map(AppleSpeechLocaleResolver.tag(for:))
        }
    }

    private var localeBinding: Binding<String> {
        Binding(
            get: { AppleSpeechLocaleResolver.tag(for: sttLocale) },
            set: { newValue in
                let canonical = AppleSpeechLocaleResolver.tag(for: newValue)
                guard canonical != AppleSpeechLocaleResolver.tag(for: sttLocale) else { return }
                sttLocale = canonical
                SttLocalePreferences.save(canonical)
                isReloading = true
                Task { @MainActor in
                    await engine.reloadSttModelIfLoaded()
                    isReloading = false
                }
            })
    }

    private var localeOptions: [String] {
        let selected = AppleSpeechLocaleResolver.tag(for: sttLocale)
        guard selected != AppleSpeechLocaleResolver.autoTag,
              !supportedLocaleTags.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame })
        else { return supportedLocaleTags }
        return [selected] + supportedLocaleTags
    }

    private func localeTitle(for tag: String) -> String {
        let name = AppleSpeechLocaleResolver.displayName(for: Locale(identifier: tag))
        return "\(name) (\(tag))"
    }
}

#Preview {
    SettingsView(engine: StsEngine())
}
