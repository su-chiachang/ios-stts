import Foundation

/// Turns an LLM text stream into short, speakable sentences. CJK sentence
/// punctuation is handled alongside Latin punctuation, and a hard limit keeps
/// a malformed or unpunctuated response from delaying TTS indefinitely.
struct SentenceChunker {
    private let minimumCharacters: Int
    private let maximumCharacters: Int
    private var pending = ""

    init(minimumCharacters: Int = 10, maximumCharacters: Int = 120) {
        self.minimumCharacters = minimumCharacters
        self.maximumCharacters = maximumCharacters
    }

    mutating func append(_ text: String) -> [String] {
        pending += text
        return drain(flushRemainder: false)
    }

    mutating func finish() -> [String] {
        drain(flushRemainder: true)
    }

    private mutating func drain(flushRemainder: Bool) -> [String] {
        var sentences: [String] = []

        while !pending.isEmpty {
            if let end = pending.firstIndex(where: Self.isSentenceBoundary) {
                let candidate = String(pending[...end])
                if candidate.count >= minimumCharacters || flushRemainder {
                    appendTrimmed(candidate, to: &sentences)
                    pending.removeSubrange(...end)
                    continue
                }
            }

            guard pending.count >= maximumCharacters else { break }
            let split = splitIndex(at: maximumCharacters)
            appendTrimmed(String(pending[..<split]), to: &sentences)
            pending.removeSubrange(..<split)
        }

        if flushRemainder {
            appendTrimmed(pending, to: &sentences)
            pending = ""
        }
        return sentences
    }

    private func splitIndex(at limit: Int) -> String.Index {
        let upper = pending.index(pending.startIndex, offsetBy: limit)
        let prefix = pending[..<upper]
        if let whitespace = prefix.lastIndex(where: { $0.isWhitespace }) {
            return pending.index(after: whitespace)
        }
        return upper
    }

    private func appendTrimmed(_ value: String, to sentences: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }

    private static func isSentenceBoundary(_ character: Character) -> Bool {
        ".?!。！？\n".contains(character)
    }
}
