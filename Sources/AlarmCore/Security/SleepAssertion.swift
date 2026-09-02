import Foundation
import IOKit.pwr_mgt

public enum SleepAssertionError: Error, Equatable {
    /// No assertion could be taken. Carries the last IOKit `IOReturn`.
    case assertionFailed(status: Int32)
}

public protocol SleepPreventing: AnyObject {
    var isHeld: Bool { get }
    /// Throws when nothing could be asserted. Mirrors how
    /// `AudioOutputControlling.forceMaxVolumeOnBuiltInSpeakers()` signals that
    /// the guarantee the caller asked for was not delivered: silent failure
    /// here would let the Mac sleep while the menu bar says "Armed".
    func acquire(reason: String) throws
    func release()
}

/// Holds both idle-sleep and system-sleep assertions while the alarm is armed.
/// Both were verified grantable on 2026-09-02; whether they defeat *clamshell*
/// sleep is recorded in the Phase 0 finding.
public final class IOKitSleepAssertion: SleepPreventing {
    private var ids: [IOPMAssertionID] = []
    public init() {}
    public var isHeld: Bool { !ids.isEmpty }

    public func acquire(reason: String) throws {
        guard ids.isEmpty else { return }
        var lastFailure: Int32 = kIOReturnError
        for type in [kIOPMAssertPreventUserIdleSystemSleep,
                     kIOPMAssertionTypePreventSystemSleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id)
            if result == kIOReturnSuccess {
                ids.append(id)
            } else {
                lastFailure = result
            }
        }
        // One of the two is enough to keep the machine awake; only a total
        // failure is worth reporting.
        guard !ids.isEmpty else {
            throw SleepAssertionError.assertionFailed(status: lastFailure)
        }
    }

    public func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
    }

    // Must be isolated to match the default main-actor isolation of the class,
    // and cannot be async (deinit cannot be async). Delegates to release() to
    // maintain a single teardown path: release() safely handles an empty ids
    // array, so it is harmless however it is reached.
    isolated deinit {
        release()
    }
}

#if DEBUG
// Test doubles are Debug-only. They are `public` so the test target and
// SwiftUI previews (both Debug builds) can reach them; shipping them in a
// Release build of a security product would export, among other things, an
// in-memory passcode store with a public accessor for the raw hash record.
public final class FakeSleepAssertion: SleepPreventing {
    public private(set) var isHeld = false
    public private(set) var acquireCount = 0
    public private(set) var releaseCount = 0
    public private(set) var lastReason: String?
    /// Models the real class's total-failure case: nothing asserted, throws.
    public var shouldFailAcquire = false
    public init() {}

    public func acquire(reason: String) throws {
        if shouldFailAcquire {
            throw SleepAssertionError.assertionFailed(status: kIOReturnError)
        }
        guard !isHeld else { return }
        isHeld = true
        acquireCount += 1
        lastReason = reason
    }

    public func release() {
        guard isHeld else { return }
        isHeld = false
        releaseCount += 1
    }
}
#endif  // DEBUG
