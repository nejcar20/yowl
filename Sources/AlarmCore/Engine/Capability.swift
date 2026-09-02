import Foundation

/// Anything that may be absent on a given build or machine. The sandboxed App
/// Store build drops features by reporting `isAvailable == false` rather than
/// by conditional compilation at the call site.
public protocol Capability: AnyObject {
    var identifier: String { get }
    var isAvailable: Bool { get }
}

/// Context handed to every response when the alarm fires.
public struct AlarmContext: Sendable, Equatable {
    public let trigger: TriggerID
    public let firedAt: Date
    public init(trigger: TriggerID, firedAt: Date) {
        self.trigger = trigger
        self.firedAt = firedAt
    }
}

/// A condition that can start the alarm.
public protocol Trigger: Capability {
    var id: TriggerID { get }
    /// Seconds the user gets to disarm before the siren starts. 0 = immediate.
    var graceSeconds: TimeInterval { get }
    func start(onFire: @escaping (TriggerID) -> Void) throws
    func stop()
}

/// An action taken when the alarm fires. Must be idempotent: `fire` may be
/// called when already firing, and `reset` when never fired.
public protocol Response: Capability {
    func fire(context: AlarmContext) async
    func reset() async
}
