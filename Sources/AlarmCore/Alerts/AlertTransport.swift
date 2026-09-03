import Foundation

public enum AlertUrgency: String, Sendable {
    case normal, high, critical
}

/// What happened, in terms no provider owns.
///
/// Deliberately carries no ntfy vocabulary. ntfy is the first transport, not an
/// assumption: a product that sells will plausibly want its own backend rather
/// than depending on a free public service's uptime and world-readable topics.
public struct AlertPayload: Sendable {
    public let title: String
    public let body: String
    public let urgency: AlertUrgency
    public let occurredAt: Date
    public let images: [Data]

    public init(title: String, body: String, urgency: AlertUrgency,
                occurredAt: Date, images: [Data]) {
        self.title = title
        self.body = body
        self.urgency = urgency
        self.occurredAt = occurredAt
        self.images = images
    }
}

public enum AlertTransportError: Error, Equatable {
    case notConfigured
    case network
    case rejected(status: Int)
}

public protocol AlertTransport: AnyObject {
    var identifier: String { get }
    var isConfigured: Bool { get }
    func send(_ payload: AlertPayload) async throws
}

// MARK: - HTTP

public struct HTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
}

public protocol HTTPPosting: AnyObject {
    func perform(_ request: HTTPRequest) async throws
}

/// The only place in the app that touches the network.
public final class URLSessionHTTPClient: HTTPPosting {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // Never let a notification outlive the alarm it is about.
        configuration.timeoutIntervalForResource = timeout * 2
        self.session = URLSession(configuration: configuration)
    }

    public func perform(_ request: HTTPRequest) async throws {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = request.body
        do {
            let (_, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw AlertTransportError.network }
            guard (200..<300).contains(http.statusCode) else {
                throw AlertTransportError.rejected(status: http.statusCode)
            }
        } catch let error as AlertTransportError {
            throw error
        } catch {
            throw AlertTransportError.network
        }
    }
}

#if DEBUG
public final class FakeHTTPClient: HTTPPosting {
    public struct Recorded: Sendable {
        public let url: URL
        public let method: String
        public let headers: [String: String]
        public let body: Data?
    }
    public private(set) var requests: [Recorded] = []
    public var failWith: Error?

    public init() {}

    public func perform(_ request: HTTPRequest) async throws {
        requests.append(Recorded(url: request.url, method: request.method,
                                 headers: request.headers, body: request.body))
        if let failWith { throw failWith }
    }
}
#endif
