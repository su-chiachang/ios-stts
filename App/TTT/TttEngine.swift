import Foundation

/// A chat message passed to Apple's Foundation Models adapter.
struct TttMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

enum TttAvailability: Equatable {
    case available
    case unavailable(TttUnavailableReason)
}

enum TttUnavailableReason: Equatable {
    case modelNotReady
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case other
}

/// Common text-to-text seam. Implementations emit response fragments, never
/// cumulative snapshots.
@MainActor
protocol TttEngine: AnyObject {
    var availability: TttAvailability { get }

    func streamChat(messages: [TttMessage]) -> AsyncThrowingStream<String, Error>
    func reset()
}
