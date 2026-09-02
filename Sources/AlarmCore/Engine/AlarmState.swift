import Foundation

/// Stable identifier for a trigger, used in logs, alerts and UI.
public struct TriggerID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum AlarmState: Equatable, Sendable {
    case disarmed
    case armed
    /// A trigger fired but the user still has until `until` to disarm.
    case grace(until: Date, trigger: TriggerID)
    case firing(trigger: TriggerID)
}

public enum AlarmEvent: Equatable, Sendable {
    case arm
    case disarm
    case triggered(TriggerID, graceSeconds: TimeInterval)
    case graceExpired
}

/// Pure transition function. No I/O, no ambient time — `now` is passed in so
/// grace deadlines are deterministic in tests.
public func reduce(_ state: AlarmState, _ event: AlarmEvent, now: Date) -> AlarmState {
    switch (state, event) {
    case (_, .disarm):
        return .disarmed

    case (.disarmed, .arm), (.armed, .arm):
        return .armed

    case let (.armed, .triggered(id, grace)):
        return grace > 0
            ? .grace(until: now.addingTimeInterval(grace), trigger: id)
            : .firing(trigger: id)

    case let (.grace(_, id), .graceExpired):
        return .firing(trigger: id)

    // Everything else is a no-op: triggers while disarmed or already firing,
    // stale grace timers, re-arming mid-alarm.
    default:
        return state
    }
}
