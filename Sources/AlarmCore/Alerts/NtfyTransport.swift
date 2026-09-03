import Foundation
import Security

/// Pushes an alert to a phone via ntfy.
///
/// **The topic name is the access control.** On ntfy.sh any topic is readable by
/// anyone who knows its name, so the name is 128 bits of randomness generated
/// per install and never shown except in the pairing QR code. A guessable topic
/// would publish photographs of the user's home to the internet.
///
/// **Pushed photos are not storage.** ntfy.sh deletes attachments after about
/// three hours and messages after twelve. The durable copy is the one on the
/// Mac; this is a notification, and the UI says so.
public final class NtfyTransport: AlertTransport {
    public let identifier = "ntfy"

    private let topic: String
    private let server: URL
    private let authToken: String?
    private let http: HTTPPosting

    public init(topic: String, http: HTTPPosting,
                server: URL = URL(string: "https://ntfy.sh")!,
                authToken: String? = nil) {
        self.topic = topic
        self.http = http
        self.server = server
        self.authToken = authToken
    }

    public var isConfigured: Bool { !topic.isEmpty }

    /// 128 bits, hex encoded, with no identifying prefix. A name like
    /// "laptopalarm-…" would tell anyone who saw the topic which app it belongs
    /// to and what the photographs in it are of, for no benefit.
    public static func generateTopic() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        // Discarding this status left `bytes` zeroed on failure, producing the
        // topic "000…0" -- guessable by anyone, publishing the user's
        // photographs to the world.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func send(_ payload: AlertPayload) async throws {
        guard isConfigured else { throw AlertTransportError.notConfigured }
        let endpoint = server.appendingPathComponent(topic)

        var headers = [
            "Title": payload.title,
            "Priority": priority(for: payload.urgency),
            "Tags": "rotating_light",
        ]
        if let authToken { headers["Authorization"] = "Bearer \(authToken)" }

        try await http.perform(HTTPRequest(url: endpoint, method: "POST",
                                           headers: headers,
                                           body: Data(payload.body.utf8)))

        // Each photo is its own request: ntfy takes one attachment per message.
        for (index, image) in payload.images.enumerated() {
            var imageHeaders = ["Filename": "alarm-\(index + 1).jpg"]
            if let authToken { imageHeaders["Authorization"] = "Bearer \(authToken)" }
            try await http.perform(HTTPRequest(url: endpoint, method: "PUT",
                                               headers: imageHeaders, body: image))
        }
    }

    private func priority(for urgency: AlertUrgency) -> String {
        switch urgency {
        case .normal: "3"
        case .high: "4"
        case .critical: "5"
        }
    }
}

/// Stores the ntfy topic. It is a secret — anyone holding it can read the
/// photographs — so it lives in the Keychain beside the passcode rather than in
/// user defaults.
/// So the alert-link store can be faked in tests.
public extension TopicStoring {
    /// The stored topic, or an empty string when there is none to use.
    func readTopicValue() -> String {
        if case let .found(value) = readTopic() { return value }
        return ""
    }
}

public protocol TopicStoring: AnyObject {
    func readTopic() -> KeychainTopicStore.TopicRead
    func topicCreatingIfNeeded() -> String?
    @discardableResult func reset() -> Bool
}

public final class KeychainTopicStore: TopicStoring {
    private let service: String
    private let account = "ntfy-topic"

    public init(service: String = "com.jernejkocica.laptopalarm") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Distinguishes "there is no link" from "the link could not be read".
    /// Collapsing both to nil meant one transient failure -- most likely at
    /// login, when the Keychain may not yet be usable and this app is a login
    /// item -- was read as "missing" and the repair path DELETED the user's
    /// live link and minted a replacement, leaving their phone subscribed to a
    /// dead topic.
    public enum TopicRead: Equatable {
        case found(String)
        case notFound
        case unreadable(OSStatus)
    }

    public func readTopic() -> TopicRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { return .unreadable(status) }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unreadable(status)
        }
    }

    public var topic: String? {
        if case let .found(value) = readTopic() { return value }
        return nil
    }

    /// Returns the existing topic, or creates one. Stable across launches so the
    /// phone stays subscribed.
    /// Returns nil rather than a topic it could not store. Returning one
    /// anyway meant alerts were sent to a topic the next launch would not
    /// remember, so the phone stayed subscribed to a dead link while the UI
    /// showed everything working.
    /// Only ever called once the caller has established the topic is genuinely
    /// absent. It deletes before adding, so calling it on an unreadable-but-
    /// present item would destroy a working link.
    public func topicCreatingIfNeeded() -> String? {
        if case let .found(existing) = readTopic() { return existing }
        guard let generated = NtfyTransport.generateTopic() else { return nil }
        var query = baseQuery
        query[kSecValueData as String] = Data(generated.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        else { return nil }
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { return nil }
        return generated
    }

    @discardableResult
    public func reset() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

#if DEBUG
public final class InMemoryTopicStore: TopicStoring {
    public var stored: KeychainTopicStore.TopicRead
    public var mintResult: String?
    public var resetResult = true
    public private(set) var mintCount = 0
    public private(set) var resetCount = 0

    public init(stored: KeychainTopicStore.TopicRead = .notFound,
                mintResult: String? = "minted-topic") {
        self.stored = stored
        self.mintResult = mintResult
    }

    public func readTopic() -> KeychainTopicStore.TopicRead { stored }

    public func topicCreatingIfNeeded() -> String? {
        if case let .found(existing) = stored { return existing }
        mintCount += 1
        if let mintResult { stored = .found(mintResult) }
        return mintResult
    }

    @discardableResult
    public func reset() -> Bool {
        resetCount += 1
        if resetResult { stored = .notFound }
        return resetResult
    }
}
#endif
