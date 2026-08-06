import Foundation

/// The text-to-text implementation selected for the ttt tab and STTS.
enum TttBackend: String, CaseIterable, Identifiable, Sendable {
    case apple
    case webapi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .webapi: "Web API"
        }
    }
}

/// A provider-neutral chat message used by the two concrete adapters.
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
