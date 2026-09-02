import Foundation
import IOKit.pwr_mgt

public protocol SleepPreventing: AnyObject {
    var isHeld: Bool { get }
    func acquire(reason: String)
    func release()
}

/// Holds both idle-sleep and system-sleep assertions while the alarm is armed.
/// Both were verified grantable on 2026-09-02; whether they defeat *clamshell*
/// sleep is recorded in the Phase 0 finding.
public final class IOKitSleepAssertion: SleepPreventing {
    private var ids: [IOPMAssertionID] = []
    public init() {}
    public var isHeld: Bool { !ids.isEmpty }

    public func acquire(reason: String) {
        guard ids.isEmpty else { return }
        for type in [kIOPMAssertPreventUserIdleSystemSleep,
                     kIOPMAssertionTypePreventSystemSleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id)
            if result == kIOReturnSuccess { ids.append(id) }
        }
    }

    public func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
    }
}

public final class FakeSleepAssertion: SleepPreventing {
    public private(set) var isHeld = false
    public private(set) var acquireCount = 0
    public private(set) var releaseCount = 0
    public private(set) var lastReason: String?
    public init() {}

    public func acquire(reason: String) {
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
