import SwiftUI

/// Lets the user fetch the STT and TTS models straight into the app's
/// sandbox container, in lieu of running scripts/fetch-models.sh by hand.
/// Each row is one downloadable asset (an STT file, a Qwen talker/codec pair,
/// or the atomic Audio8 generator/codec/tokenizer group).
struct DownloadModelsView: View {
    var settings = AppSettings.shared
    var manager = ModelDownloadManager.shared
    var onModelsChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("speech-to-text") {
                ForEach(ModelCatalog.sttAssets) { asset in
                    ModelAssetRow(asset: asset, manager: manager, isSelected: true, onFinished: notifyChanged)
                }
            }

            Section("Qwen text-to-speech") {
                ForEach(ModelCatalog.ttsAssets) { asset in
                    ModelAssetRow(asset: asset, manager: manager,
                                  isSelected: settings.ttsBackend == .qwen
                                      && asset.id == "tts.\(settings.qwenModelVariant.rawValue).\(settings.qwenModelQuantization.rawValue)",
                                  onFinished: notifyChanged)
                }
                Text("F16 downloads the upstream BF16 pair. Q4_K_M is the default compact option; Q8_0 uses more memory for higher precision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio8 text-to-speech") {
                ForEach(ModelCatalog.audio8Assets) { asset in
                    ModelAssetRow(asset: asset, manager: manager,
                                  isSelected: settings.ttsBackend == .audio8,
                                  onFinished: notifyChanged)
                }
                Text("Audio8 requires one generator GGUF, one codec GGUF, and tokenizer.json. Its download URLs are not configured until a versioned model release is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 520, height: 420)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func notifyChanged() {
        onModelsChanged?()
    }
}

private struct ModelAssetRow: View {
    let asset: ModelAsset
    var manager: ModelDownloadManager
    let isSelected: Bool
    let onFinished: () -> Void

    var body: some View {
        let state = manager.state(for: asset)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(asset.title).font(.headline)
                        if isSelected {
                            Text("selected").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(asset.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                actionButton(for: state)
            }
            statusView(for: state)
        }
        .padding(.vertical, 4)
        .onChange(of: state) { _, newValue in
            if newValue == .completed { onFinished() }
        }
    }

    @ViewBuilder
    private func actionButton(for state: ModelDownloadState) -> some View {
        if let configurationError = asset.configurationError {
            if state == .completed {
                Button("Installed") {}.disabled(true)
                Text("Local files are ready; " + configurationError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Unavailable") {}.disabled(true)
                Text(configurationError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch state {
            case .notStarted, .failed, .cancelled:
                Button("Download") { manager.start(asset) }
            case .downloading:
                Button("Cancel") { manager.cancel(asset) }
            case .completed:
                Button("Re-download") { manager.start(asset) }
            }
        }
    }

    @ViewBuilder
    private func statusView(for state: ModelDownloadState) -> some View {
        switch state {
        case .notStarted:
            EmptyView()
        case .downloading(let fraction, let received, let total):
            VStack(alignment: .leading, spacing: 2) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(progressCaption(received: received, total: total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .completed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressCaption(received: Int64, total: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let receivedText = formatter.string(fromByteCount: received)
        guard let total else { return receivedText }
        let totalText = formatter.string(fromByteCount: total)
        return "\(receivedText) / \(totalText)"
    }
}

#Preview {
    DownloadModelsView()
}
