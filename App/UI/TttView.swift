import SwiftUI
import FoundationModels
#if os(iOS)
import UIKit
#endif

/// The [ttt] tab: a single on-device chat conversation against
/// `LanguageModelSession`. Shape settled in wayfinder ticket #23 — iMessage-
/// style bubbles, pinned input bar, always-visible New Chat icon, inline
/// unavailable banner. https://github.com/su-chiachang/ios-stts/issues/23
struct TttView: View {
    @State private var engine = TttEngine()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(engine.messages) { message in
                            bubble(for: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: engine.messages.count) {
                    if let last = engine.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            switch engine.model.availability {
            case .available:
                inputBar
            case .unavailable(let reason):
                unavailableBanner(reason)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("ttt").font(.headline)
            Spacer()
            Button { engine.newChat() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New Chat")
        }
        .padding()
    }

    private func bubble(for message: TttEngine.Message) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                messageText(message)
                if case .error(let retryable) = message.kind, retryable {
                    Button("Retry") { engine.retry(message) }
                        .font(.caption)
                }
            }
            .padding(10)
            .background(bubbleBackground(for: message), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(message.role == .user ? .white : .primary)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private func messageText(_ message: TttEngine.Message) -> some View {
        Group {
            if message.role == .assistant, case .normal = message.kind {
                Text(markdown(message.text))
            } else {
                Text(message.text)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func bubbleBackground(for message: TttEngine.Message) -> AnyShapeStyle {
        if case .error = message.kind {
            return AnyShapeStyle(.red.opacity(0.15))
        }
        return message.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
    }

    private var inputBar: some View {
        HStack {
            Image(systemName: "paperclip")
                .foregroundStyle(.tertiary)
            TextField("Message", text: $engine.draft, axis: .vertical)
                .disabled(engine.isSessionExhausted)
            Button("Send") { engine.send() }
                .disabled(!engine.canSend)
        }
        .padding()
    }

    private func unavailableBanner(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(unavailableTitle(reason)).font(.caption).bold()
                if let detail = unavailableDetail(reason) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            #if os(iOS)
            if reason == .appleIntelligenceNotEnabled {
                Button("Open Settings") { openSettings() }
                    .font(.caption)
            }
            #endif
        }
        .padding()
    }

    private func unavailableTitle(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .modelNotReady: "Waiting for the on-device model to finish downloading…"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .deviceNotEligible: "This device doesn't support Apple Intelligence"
        @unknown default: "ttt isn't available right now"
        }
    }

    private func unavailableDetail(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String? {
        switch reason {
        case .modelNotReady: "ttt will become active automatically once it's ready."
        case .appleIntelligenceNotEnabled: "Turn it on in Settings to use ttt."
        default: nil
        }
    }

    #if os(iOS)
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    #endif
}

#Preview {
    TttView()
}
