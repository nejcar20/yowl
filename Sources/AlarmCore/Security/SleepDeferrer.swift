import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds off a sleep that is already happening.
public protocol SleepDeferring: AnyObject {
    /// `shouldDefer` is asked at the moment the system announces a sleep. It is
    /// a closure rather than a stored flag so the answer is always current.
    func start(shouldDefer: @escaping () -> Bool)
    func stop()
}

/// Closing the lid sleeps the Mac and no power assertion prevents it. But an app
/// registered with `IORegisterForSystemPower` is *asked* first, and Apple's own
/// header spells out the lever: a caller that does not acknowledge
/// `kIOMessageSystemWillSleep` stalls the sleep for "a 30 second timeout
/// (resulting in bad user experience)".
///
/// Bad user experience is the point. Thirty more seconds of siren in the hands
/// of whoever just shut the lid is the whole reason this exists — and idle
/// sleep, which arrives as the abortable `kIOMessageCanSystemSleep`, is
/// cancelled outright while the alarm is running.
///
/// Both answers are asked of `shouldDefer`, so a Mac that is not firing sleeps
/// exactly as it always did. Getting that backwards would mean an alarm app
/// that stops every ordinary sleep for half a minute.
public final class IOKitSleepDeferrer: SleepDeferring {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_connect_t = 0
    private var shouldDefer: (() -> Bool)?
    /// Held so a deferred sleep can be released early if the alarm ends before
    /// the system's own timeout does.
    private var pendingSleep: intptr_t?

    /// From `IOMessage.h`: `iokit_common_msg(m)` is `sys_iokit | sub_iokit_common
    /// | m`, i.e. `0xE0000000 | m`. The macros themselves do not survive the
    /// Swift importer, so the two values are written out.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280

    public init() {}

    public func start(shouldDefer: @escaping () -> Bool) {
        stop()
        self.shouldDefer = shouldDefer
        let me = Unmanaged.passUnretained(self).toOpaque()
        var notifierOut: io_object_t = 0
        var portOut: IONotificationPortRef?
        let connection = IORegisterForSystemPower(me, &portOut, { refcon, _, type, argument in
            guard let refcon else { return }
            let deferrer = Unmanaged<IOKitSleepDeferrer>.fromOpaque(refcon)
                .takeUnretainedValue()
            // The run loop source below is on the main run loop, so this arrives
            // on the main thread.
            MainActor.assumeIsolated {
                deferrer.handle(type: type, argument: intptr_t(bitPattern: argument))
            }
        }, &notifierOut)
        guard connection != MACH_PORT_NULL, let portOut else { return }
        root = connection
        port = portOut
        notifier = notifierOut
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(portOut).takeUnretainedValue(),
                           .commonModes)
    }

    public func stop() {
        // A deferred sleep must be released before tearing down, or the Mac
        // waits out the full timeout with nobody left to answer for it.
        releasePendingSleep()
        if let port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                                  .commonModes)
            if notifier != 0 { IODeregisterForSystemPower(&notifier) }
            IOServiceClose(root)
            IONotificationPortDestroy(port)
        }
        port = nil
        notifier = 0
        root = 0
        shouldDefer = nil
    }

    /// Lets a held-off sleep proceed. Called when the alarm ends, so disarming
    /// during the stall does not leave the Mac awake for the rest of the window.
    public func releasePendingSleep() {
        guard let pending = pendingSleep, root != 0 else { return }
        IOAllowPowerChange(root, pending)
        pendingSleep = nil
    }

    private func handle(type: UInt32, argument: intptr_t) {
        let defer_ = shouldDefer?() ?? false
        switch type {
        case Self.canSystemSleep:
            // Idle sleep, and abortable. Refusing outright is right here: the
            // machine has been sitting untouched *because* nobody is meant to
            // be at it.
            if defer_ { IOCancelPowerChange(root, argument) }
            else { IOAllowPowerChange(root, argument) }
        case Self.systemWillSleep:
            // Not abortable. Withholding the acknowledgement buys the timeout.
            if defer_ { pendingSleep = argument }
            else { IOAllowPowerChange(root, argument) }
        default:
            break
        }
    }

    isolated deinit { stop() }
}

#if DEBUG
public final class FakeSleepDeferrer: SleepDeferring {
    private var shouldDefer: (() -> Bool)?
    public private(set) var isObserving = false
    public private(set) var releaseCount = 0
    public init() {}
    public func start(shouldDefer: @escaping () -> Bool) {
        self.shouldDefer = shouldDefer; isObserving = true
    }
    public func stop() { isObserving = false }
    /// What the app would answer if the system announced a sleep right now.
    public func wouldDefer() -> Bool { shouldDefer?() ?? false }
}
#endif
