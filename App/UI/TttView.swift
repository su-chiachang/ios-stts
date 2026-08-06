import Foundation
import FoundationModels
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The [ttt] tab: one chat surface backed by the provider selected in
/// Settings. The view owns the presentation state; the provider owns only
/// text generation.
@MainActor
struct TttView: View {
    let settings: AppSettings
    @State private var provider: any TttEngine
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var isStreaming = false
    @State private var isSessionExhausted = false
    @State private var lastUserPrompt: String?
    @State private var responseTask: Task<Void, Never>?

    init(settings: AppSettings = .shared) {
        self.settings = settings
        _provider = State(initialValue: Self.makeProvider(
            backend: settings.tttBackend,
            settings: settings
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            bubble(for: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            switch provider.availability {
            case .available:
                inputBar
            case .unavailable(let reason):
                unavailableBanner(reason)
            }
        }
        .onChange(of: settings.tttBackend) { _, backend in
            switchProvider(to: backend)
        }
        .onDisappear {
            responseTask?.cancel()
        }
    }

    private struct Message: Identifiable {
        enum Role: Equatable { case user, assistant }
        enum Kind: Equatable {
            case normal
            case error(retryable: Bool)
        }

        let id: UUID
        let role: Role
        var text: String
        var kind: Kind

        init(id: UUID = UUID(), role: Role, text: String, kind: Kind = .normal) {
            self.id = id
            self.role = role
            self.text = text
            self.kind = kind
        }
    }

    private static func makeProvider(backend: TttBackend,
                                     settings: AppSettings) -> any TttEngine {
        switch backend {
        case .apple:
            TttApple()
        case .webapi:
            TttWebapi(settings: settings)
        }
    }

    private var header: some View {
        HStack {
            Text("ttt").font(.headline)
            Spacer()
            Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New Chat")
        }
        .padding()
    }

    private func bubble(for message: Message) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                messageText(message)
                if case .error(let retryable) = message.kind, retryable {
                    Button("Retry") { retry(message) }
                        .font(.caption)
                }
            }
            .padding(10)
            .background(bubbleBackground(for: message), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(message.role == .user ? .white : .primary)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private func messageText(_ message: Message) -> some View {
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

    private func bubbleBackground(for message: Message) -> AnyShapeStyle {
        if case .error = message.kind {
            return AnyShapeStyle(.red.opacity(0.15))
        }
        return message.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
    }

    private var inputBar: some View {
        HStack {
            Button {} label: { Image(systemName: "paperclip") }
                .disabled(true)
                .foregroundStyle(.tertiary)
            TextField("Message", text: $draft, axis: .vertical)
                .disabled(isSessionExhausted)
            Button("Send") { send() }
                .disabled(!canSend)
        }
        .padding()
    }

    private var canSend: Bool {
        !isStreaming && !isSessionExhausted
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, !isSessionExhausted else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        stream(prompt: text)
    }

    private func retry(_ message: Message) {
        guard case .error(let retryable) = message.kind,
              retryable,
              let prompt = lastUserPrompt,
              !isStreaming,
              !isSessionExhausted else { return }
        messages.removeAll { $0.id == message.id }
        stream(prompt: prompt)
    }

    private func newChat() {
        responseTask?.cancel()
        responseTask = nil
        provider.reset()
        messages.removeAll()
        draft = ""
        isStreaming = false
        isSessionExhausted = false
        lastUserPrompt = nil
    }

    private func switchProvider(to backend: TttBackend) {
        responseTask?.cancel()
        responseTask = nil
        provider.reset()
        provider = Self.makeProvider(backend: backend, settings: settings)
        messages.removeAll()
        draft = ""
        isStreaming = false
        isSessionExhausted = false
        lastUserPrompt = nil
    }

    private func stream(prompt: String) {
        guard !isStreaming else { return }
        lastUserPrompt = prompt
        isStreaming = true
        let requestMessages = makeRequestMessages()
        let assistantID = UUID()
        messages.append(Message(id: assistantID, role: .assistant, text: ""))
        let provider = provider

        responseTask = Task { @MainActor in
            defer { isStreaming = false }
            do {
                for try await fragment in provider.streamChat(messages: requestMessages) {
                    try Task.checkCancellation()
                    guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
                    messages[index].text += fragment
                }
                if let index = messages.firstIndex(where: { $0.id == assistantID }),
                   messages[index].text.isEmpty {
                    messages.remove(at: index)
                }
            } catch is CancellationError {
                // A new chat or provider switch owns cancellation.
            } catch let error as LanguageModelSession.GenerationError {
                guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
                messages[index] = errorMessage(for: error)
            } catch {
                guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
                messages[index] = Message(
                    id: assistantID,
                    role: .assistant,
                    text: "Couldn't get a response. Try again.",
                    kind: .error(retryable: true)
                )
            }
        }
    }

    private func makeRequestMessages() -> [TttMessage] {
        let systemMessages = settings.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? [] : [TttMessage(role: .system, content: settings.systemPrompt)]
        let conversation = messages.compactMap { message -> TttMessage? in
            guard case .normal = message.kind else { return nil }
            return TttMessage(
                role: message.role == .user ? .user : .assistant,
                content: message.text
            )
        }
        return systemMessages + conversation
    }

    private func errorMessage(for error: LanguageModelSession.GenerationError) -> Message {
        switch error {
        case .exceededContextWindowSize:
            isSessionExhausted = true
            return Message(
                role: .assistant,
                text: "This conversation's gotten too long for the model to continue. Start a new chat to keep going.",
                kind: .error(retryable: false)
            )
        case .guardrailViolation, .refusal:
            return Message(role: .assistant, text: "This can't be answered.", kind: .error(retryable: false))
        case .unsupportedLanguageOrLocale:
            return Message(role: .assistant, text: "This language isn't supported.", kind: .error(retryable: false))
        case .unsupportedGuide, .decodingFailure, .assetsUnavailable:
            return Message(role: .assistant,
                           text: "Something about this request isn't supported.",
                           kind: .error(retryable: false))
        case .rateLimited, .concurrentRequests:
            return Message(role: .assistant, text: "Couldn't get a response. Try again.", kind: .error(retryable: true))
        @unknown default:
            return Message(role: .assistant, text: "Couldn't get a response. Try again.", kind: .error(retryable: true))
        }
    }

    private func unavailableBanner(_ reason: TttUnavailableReason) -> some View {
        let info = unavailableInfo(reason)
        return HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.caption).bold()
                if let detail = info.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if reason == .appleIntelligenceNotEnabled {
                Button("Open Settings") { openSettings() }
                    .font(.caption)
            }
        }
        .padding()
    }

    private func unavailableInfo(_ reason: TttUnavailableReason) -> (title: String, detail: String?) {
        switch reason {
        case .modelNotReady:
            ("Waiting for the on-device model to finish downloading…",
             "ttt will become active automatically once it's ready.")
        case .appleIntelligenceNotEnabled:
            ("Apple Intelligence is off", "Turn it on in Settings to use ttt.")
        case .deviceNotEligible:
            ("This device doesn't support Apple Intelligence", nil)
        case .other:
            ("ttt isn't available right now", nil)
        }
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

#Preview {
    TttView()
}
