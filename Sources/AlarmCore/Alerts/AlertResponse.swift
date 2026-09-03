import Foundation

/// Tells the user's phone that the alarm went off, with photographs if there
/// are any.
///
/// Knows nothing about ntfy: it holds an `AlertTransport` and could push, email
/// or POST to the user's own server without changing.
public final class AlertResponse: Response {
    public let identifier = "alert"
    /// Off unless asked for: it sends photographs of people off the machine.
    public var isEnabled = false

    private var transport: AlertTransport
    private let evidence: EvidenceStoring
    private var inFlight: Task<Void, Never>?

    public init(transport: AlertTransport, evidence: EvidenceStoring) {
        self.transport = transport
        self.evidence = evidence
    }

    /// Nowhere to send is not protection, and must not be counted as any.
    public var isAvailable: Bool { transport.isConfigured }

    /// Swaps the destination — a rotated topic, or one day a different provider
    /// entirely, which is why the response holds a protocol and not an ntfy.
    public func replaceTransport(_ transport: AlertTransport) {
        self.transport = transport
    }

    /// Sends a message the user asked for, so pairing can be verified before
    /// they rely on it. Returns whether it arrived at the server.
    public func sendTest() async -> Bool {
        do {
            try await transport.send(AlertPayload(
                title: "LaptopAlarm",
                body: "Test alert — your Mac can reach you.",
                urgency: .normal,
                occurredAt: Date(),
                images: []))
            return true
        } catch {
            return false
        }
    }

    public func fire(context: AlarmContext) async {
        inFlight?.cancel()
        // Detached from the alarm: a slow or dead network must never delay the
        // siren, and a transport failure must never propagate into the engine.
        inFlight = Task { [transport, evidence] in
            let payload = AlertPayload(
                title: "LaptopAlarm",
                body: Self.describe(context),
                urgency: .critical,
                occurredAt: context.firedAt,
                images: Self.recentImages(from: evidence))
            try? await transport.send(payload)
        }
    }

    public func reset() async {
        inFlight?.cancel()
        inFlight = nil
    }

    static func describe(_ context: AlarmContext) -> String {
        switch context.trigger.rawValue {
        case "power": "The charger was unplugged."
        case "motion": "The laptop was moved."
        case "lid": "The lid was closed."
        default: "The alarm was triggered."
        }
    }

    /// Sends at most a few photographs: enough to identify someone, few enough
    /// that a phone notification is not a slideshow.
    static func recentImages(from store: EvidenceStoring, limit: Int = 3) -> [Data] {
        store.recentJPEGs(limit: limit)
    }
}
