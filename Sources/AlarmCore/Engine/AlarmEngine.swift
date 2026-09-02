import Foundation

public enum AlarmEngineError: Error, Equatable {
    case noPasscodeSet
}

/// Orchestrates triggers, responses and the state machine.
///
/// Main-actor isolated: triggers deliver callbacks from IOKit run-loop sources
/// and the UI observes state, so a single actor removes the need for locking.
public final class AlarmEngine {
    private let triggers: [any Trigger]
    private let responses: [any Response]
    private let clock: AlarmClock
    private let passcodes: PasscodeStoring
    private let sleepAssertion: SleepPreventing?
    private var graceWork: ScheduledWork?

    public private(set) var state: AlarmState = .disarmed {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public var onStateChange: ((AlarmState) -> Void)?

    public init(triggers: [any Trigger],
                responses: [any Response],
                clock: AlarmClock,
                passcodes: PasscodeStoring,
                sleepAssertion: SleepPreventing?) {
        // Capability gating: unavailable features are dropped here, once.
        self.triggers = triggers.filter(\.isAvailable)
        self.responses = responses.filter(\.isAvailable)
        self.clock = clock
        self.passcodes = passcodes
        self.sleepAssertion = sleepAssertion
    }

    public func arm() throws {
        guard passcodes.hasPasscode else { throw AlarmEngineError.noPasscodeSet }
        guard state == .disarmed else { return }

        // State is set to .armed before any trigger is started so a trigger
        // that calls back synchronously during start() (e.g. an
        // already-tripped lid-angle sensor) lands on a real .armed state
        // rather than a .disarmed one the reducer would silently no-op.
        sleepAssertion?.acquire(reason: "LaptopAlarm armed")
        state = reduce(state, .arm, now: clock.now)

        for trigger in triggers {
            let grace = trigger.graceSeconds
            try? trigger.start { [weak self] id in
                self?.handleTrigger(id, graceSeconds: grace)
            }
        }
    }

    @discardableResult
    public func disarm(passcode: String) -> Bool {
        guard passcodes.verify(passcode) else { return false }
        graceWork?.cancel()
        graceWork = nil
        triggers.forEach { $0.stop() }
        sleepAssertion?.release()
        state = reduce(state, .disarm, now: clock.now)
        Task { for response in responses { await response.reset() } }
        return true
    }

    func handleTrigger(_ id: TriggerID, graceSeconds: TimeInterval) {
        let next = reduce(state, .triggered(id, graceSeconds: graceSeconds),
                          now: clock.now)
        guard next != state else { return }
        state = next

        switch next {
        case .grace:
            graceWork = clock.schedule(after: graceSeconds) { [weak self] in
                self?.graceExpired()
            }
        case .firing:
            fireResponses(trigger: id)
        default:
            break
        }
    }

    private func graceExpired() {
        let next = reduce(state, .graceExpired, now: clock.now)
        guard next != state else { return }
        state = next
        if case let .firing(id) = next { fireResponses(trigger: id) }
    }

    private func fireResponses(trigger: TriggerID) {
        let context = AlarmContext(trigger: trigger, firedAt: clock.now)
        Task { for response in responses { await response.fire(context: context) } }
    }
}
