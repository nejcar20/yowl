import Foundation

#if DEBUG
// Test doubles are Debug-only. They are `public` so the test target and
// SwiftUI previews (both Debug builds) can reach them; shipping them in a
// Release build of a security product would export, among other things, an
// in-memory passcode store with a public accessor for the raw hash record.
public final class FakeTrigger: Trigger {
    public let id: TriggerID
    public let isAvailable: Bool
    public var isEnabled = true
    public var graceSeconds: TimeInterval
    /// Defaults to true so existing tests keep arming; set false to model an
    /// edge-detected trigger whose edge has already passed.
    public let canFireNow: Bool
    public var identifier: String { id.rawValue }
    public private(set) var isStarted = false
    private var onFire: ((TriggerID) -> Void)?

    public init(id: TriggerID, isAvailable: Bool = true, graceSeconds: TimeInterval = 0,
                canFireNow: Bool = true) {
        self.id = id
        self.isAvailable = isAvailable
        self.graceSeconds = graceSeconds
        self.canFireNow = canFireNow
    }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        self.onFire = onFire
        isStarted = true
    }

    public func stop() {
        isStarted = false
        onFire = nil
    }

    /// Drives the trigger from a test.
    public func simulateFire() { onFire?(id) }
}

public final class FakeResponse: Response {
    public let identifier: String
    public let isAvailable: Bool
    public var isEnabled = true
    public private(set) var fireCount = 0
    public private(set) var resetCount = 0
    public private(set) var lastContext: AlarmContext?

    public init(identifier: String, isAvailable: Bool = true) {
        self.identifier = identifier
        self.isAvailable = isAvailable
    }

    public func fire(context: AlarmContext) async {
        fireCount += 1
        lastContext = context
    }

    public func reset() async { resetCount += 1 }
}


/// A trigger whose `start` always fails, for the case Phase 1 never had: a
/// trigger that genuinely cannot begin watching.
public final class ThrowingTrigger: Trigger {
    public let id: TriggerID
    public var identifier: String { id.rawValue }
    public let isAvailable = true
    public var isEnabled = true
    public var graceSeconds: TimeInterval = 0
    public var canFireNow: Bool { true }

    public init(id: TriggerID) { self.id = id }

    public func start(onFire: @escaping (TriggerID) -> Void) throws {
        throw FrameSourceError.cameraUnavailable
    }

    public func stop() {}
}
#endif  // DEBUG
