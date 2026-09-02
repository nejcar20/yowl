import Foundation

public enum AlarmEngineError: Error, Equatable {
    case noPasscodeSet
    /// Every available trigger reported `canFireNow == false`, so arming would
    /// produce a shield icon and zero protection. Deliberately blocks the arm
    /// instead of warning: "Armed" must mean protected.
    case noArmableTrigger
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
    /// Invoked after every response's `fire(context:)` has returned for a
    /// given alarm firing. Mirrors `onStateChange`: one outward-facing
    /// callback per concern, so callers never need a second mechanism
    /// (e.g. polling) to learn when response side effects have settled.
    public var onResponsesFired: (() -> Void)?

    /// True when the last successful `arm()` could not take a sleep assertion,
    /// so the Mac may sleep and stop observing triggers. Arming is *not*
    /// blocked on this: a machine kept awake by other means (lid open, another
    /// app's assertion, Amphetamine) is still protected, so a warning beats a
    /// refusal. Cleared on every arm and disarm.
    public private(set) var sleepAssertionFailed = false

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

        // Pre-flight (spec §4's `arming` state): every check that can refuse
        // the arm runs *before* any side effect, so a failed arm leaves
        // nothing half-configured -- no sleep assertion held, no state change,
        // no started triggers.
        // `isEnabled` is a user preference and is re-read on every arm, unlike
        // `isAvailable`, which is a fixed property of the build and filtered
        // once at construction. A trigger counts only if the user wants it on
        // AND it has something left to detect.
        let armable = triggers.filter { $0.isActive && $0.canFireNow }
        guard !armable.isEmpty else {
            throw AlarmEngineError.noArmableTrigger
        }

        // The sleep assertion is best-effort: record the failure for the UI to
        // warn about, but keep arming. See `sleepAssertionFailed`.
        sleepAssertionFailed = false
        do {
            try sleepAssertion?.acquire(reason: "LaptopAlarm armed")
        } catch {
            sleepAssertionFailed = true
        }

        // State is set to .armed before any trigger is started so a trigger
        // that calls back synchronously during start() (e.g. an
        // already-tripped lid-angle sensor) lands on a real .armed state
        // rather than a .disarmed one the reducer would silently no-op.
        state = reduce(state, .arm, now: clock.now)

        for trigger in armable {
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
        sleepAssertionFailed = false
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
        Task {
            // Re-check state: this Task is unstructured, so a disarm can land
            // between scheduling and running. Without the guard the disarm's
            // `reset` Task can drain first and this one would then start the
            // siren *after* the reset -- state .disarmed, savedState cleared,
            // UI showing "Arm", and a screaming machine with no way to stop it.
            guard case .firing = state else { return }
            for response in responses where response.isActive {
                await response.fire(context: context)
            }
            onResponsesFired?()
        }
    }
}
