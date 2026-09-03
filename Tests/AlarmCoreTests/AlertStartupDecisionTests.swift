import Testing
import Foundation
@testable import AlarmCore

// Minting a replacement topic DELETES the existing Keychain item first. So the
// difference between "there is no link" and "the link could not be read" is the
// difference between a harmless repair and destroying a working pairing — with
// the user's phone left subscribed to a dead link. A login item starts exactly
// when the Keychain is least likely to be readable, so this is not exotic.
@Test func anUnreadableLinkIsNeverReplaced() {
    #expect(AlertStartupDecision.decide(preferenceEnabled: true,
                                        read: .unreadable(-25300)) == .pauseUnreadable)
}

@Test func agenuinelyMissingLinkIsMinted() {
    #expect(AlertStartupDecision.decide(preferenceEnabled: true,
                                        read: .notFound) == .mint)
}

@Test func anExistingLinkIsUsedAsIs() {
    #expect(AlertStartupDecision.decide(preferenceEnabled: true,
                                        read: .found("abc123")) == .use(topic: "abc123"))
}

// Nothing happens to a user who never switched alerts on — no topic is minted,
// so someone who never uses the feature never has one.
@Test func alertsLeftOffDoNothingWhateverTheKeychainSays() {
    for read: KeychainTopicStore.TopicRead in [.notFound, .unreadable(-1), .found("x")] {
        #expect(AlertStartupDecision.decide(preferenceEnabled: false, read: read) == .leaveOff)
    }
}

// An empty stored value is corruption, not a link: treating it as found would
// reproduce the "toggle on, alerts inert" bug exactly.
@Test func anEmptyStoredValueIsNotTreatedAsALink() {
    // KeychainTopicStore.readTopic maps an empty value to .unreadable, so the
    // decision must pause rather than mint or use.
    #expect(AlertStartupDecision.decide(preferenceEnabled: true,
                                        read: .unreadable(0)) == .pauseUnreadable)
}
