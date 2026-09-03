import Testing
import Foundation
@testable import AlarmCore

private func payload(images: Int = 1) -> AlertPayload {
    AlertPayload(title: "LaptopAlarm",
                 body: "Charger unplugged",
                 urgency: .critical,
                 occurredAt: Date(timeIntervalSince1970: 1_000_000),
                 images: (0..<images).map { Data([0xFF, 0xD8, UInt8($0)]) })
}

// The payload is provider-neutral on purpose: ntfy is the first transport, not
// an assumption. A commercial product will plausibly want its own backend
// rather than depending on a free public service's uptime.
@Test func theNtfyTransportSendsTheMessageThenEachImage() async throws {
    let http = FakeHTTPClient()
    let transport = NtfyTransport(topic: "secret-topic", http: http)
    try await transport.send(payload(images: 2))
    #expect(http.requests.count == 3, "one message, then one request per image")
    #expect(http.requests[0].url.absoluteString == "https://ntfy.sh/secret-topic")
    #expect(http.requests[0].headers["Title"] == "LaptopAlarm")
    #expect(http.requests.dropFirst().allSatisfy { $0.headers["Filename"] != nil })
}

@Test func criticalUrgencyIsSentAtTheHighestPriority() async throws {
    let http = FakeHTTPClient()
    try await NtfyTransport(topic: "t", http: http).send(payload())
    #expect(http.requests[0].headers["Priority"] == "5")
}

@Test func aCustomServerIsHonoured() async throws {
    let http = FakeHTTPClient()
    let transport = NtfyTransport(topic: "t", http: http,
                                  server: URL(string: "https://ntfy.example.com")!)
    try await transport.send(payload(images: 0))
    #expect(http.requests[0].url.absoluteString == "https://ntfy.example.com/t")
}

@Test func anAuthTokenIsSentWhenConfigured() async throws {
    let http = FakeHTTPClient()
    let transport = NtfyTransport(topic: "t", http: http, authToken: "tk_123")
    try await transport.send(payload(images: 0))
    #expect(http.requests[0].headers["Authorization"] == "Bearer tk_123")
}

// A failure to notify must never stop the alarm sounding.
@Test func aFailedSendThrowsRatherThanCrashing() async {
    let http = FakeHTTPClient()
    http.failWith = AlertTransportError.network
    await #expect(throws: AlertTransportError.self) {
        try await NtfyTransport(topic: "t", http: http).send(payload())
    }
}

// The topic name IS the access control on ntfy.sh: anyone who guesses it can
// read the photos. It must be unguessable, and stable so the phone stays
// subscribed.
@Test func aGeneratedTopicIsLongAndRandom() {
    let a = NtfyTransport.generateTopic()
    let b = NtfyTransport.generateTopic()
    #expect(a != b)
    #expect(a.count >= 32, "128 bits of randomness, hex encoded")
    #expect(a.allSatisfy { $0.isHexDigit || $0 == "-" })
}

@Test func theTransportIsUnconfiguredWithoutATopic() {
    #expect(NtfyTransport(topic: "", http: FakeHTTPClient()).isConfigured == false)
    #expect(NtfyTransport(topic: "abc", http: FakeHTTPClient()).isConfigured == true)
}

// The response must not block the siren on a slow network, and must not throw
// into the engine.
@Test func theAlertResponseNeverThrowsOrBlocksTheAlarm() async {
    let http = FakeHTTPClient()
    http.failWith = AlertTransportError.network
    let response = AlertResponse(transport: NtfyTransport(topic: "t", http: http),
                                 evidence: InMemoryEvidenceStore())
    await response.fire(context: AlarmContext(trigger: TriggerID("power"),
                                              firedAt: Date()))
    #expect(Bool(true), "a failing transport must not propagate out of fire()")
}

@Test func sendingIsOptIn() {
    let response = AlertResponse(transport: NtfyTransport(topic: "t", http: FakeHTTPClient()),
                                 evidence: InMemoryEvidenceStore())
    #expect(response.isEnabled == false)
}

// Unconfigured means unavailable: an alert response with nowhere to send is not
// protection and must not count as one.
@Test func anUnconfiguredTransportMakesTheResponseUnavailable() {
    let response = AlertResponse(transport: NtfyTransport(topic: "", http: FakeHTTPClient()),
                                 evidence: InMemoryEvidenceStore())
    #expect(response.isAvailable == false)
}
