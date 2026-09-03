import Foundation

/// What to do about phone alerts at launch, given what the Keychain said.
///
/// Extracted as a pure function because the rule it encodes is dangerous and
/// otherwise untestable: minting a replacement topic DELETES first, so treating
/// "could not read" as "not there" destroys a working link and leaves the
/// user's phone subscribed to a dead one. A login item starts exactly when the
/// Keychain is least likely to be readable.
public enum AlertStartupDecision: Equatable {
    /// A link exists; use it.
    case use(topic: String)
    /// No link exists and the user wants alerts; create one.
    case mint
    /// Leave the stored preference alone and try again later. Never deletes.
    case pauseUnreadable
    /// The user does not want alerts.
    case leaveOff

    public static func decide(preferenceEnabled: Bool,
                              read: KeychainTopicStore.TopicRead) -> AlertStartupDecision {
        guard preferenceEnabled else { return .leaveOff }
        switch read {
        case let .found(topic): return .use(topic: topic)
        case .notFound: return .mint
        case .unreadable: return .pauseUnreadable
        }
    }
}
