import SwiftUI

/// Lets the user fetch the STT and TTS models straight into the app's
/// sandbox container, in lieu of running scripts/fetch-models.sh by hand.
/// Each row is one downloadable asset (an STT file, or a talker+tokenizer
/// TTS variant pair) with its own progress bar and Download/Cancel action.
struct DownloadModelsView: View {
    var settings = AppSettings.shared
    var manager = ModelDownloadManager.shared
    var onModelsChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Speech-to-text") {
                ForEach(ModelCatalog.sttAssets) { asset in
                    ModelAssetRow(asset: asset, manager: manager, isSelected: true, onFinished: notifyChanged)
                }
            }

            Section("Text-to-speech") {
                ForEach(ModelCatalog.ttsAssets) { asset in
                    ModelAssetRow(asset: asset, manager: manager,
                                  isSelected: asset.id == "tts.\(settings.qwenModelVariant.rawValue)",
                                  onFinished: notifyChanged)
                }
                Text("Download the talker/codec pair for the mode you want, then select that checkpoint in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
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
        switch state {
        case .notStarted, .failed, .cancelled:
            Button("Download") { manager.start(asset) }
        case .downloading:
            Button("Cancel") { manager.cancel(asset) }
        case .completed:
            Button("Re-download") { manager.start(asset) }
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
