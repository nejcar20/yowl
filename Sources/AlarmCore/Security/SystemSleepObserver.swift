import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tells the app when the Mac is about to sleep and when it has woken.
public protocol SystemSleepObserving: AnyObject {
    func startObserving(onWillSleep: @escaping () -> Void,
                        onDidWake: @escaping () -> Void)
    func stop()
}

#if canImport(AppKit)
/// Backed by `NSWorkspace` sleep and wake notifications.
///
/// There is deliberately no "prevent sleep" here. Closing the lid sleeps the
/// machine whatever assertion is held -- Apple's IOPMLib header says the system
/// "may still sleep for lid close" -- and the `pmset disablesleep` override that
/// once forced it does not exist on Apple Silicon. Waking is the only part of it
/// an application can act on.
///
/// Registered by selector rather than with a closure. The closure-based API
/// takes a `@Sendable` block, and capturing a main-actor callback inside one is
/// a data-race warning this package does not suppress; a target/selector
/// registration captures nothing.
public final class WorkspaceSleepObserver: NSObject, SystemSleepObserving {
    private var onWillSleep: (() -> Void)?
    private var onDidWake: (() -> Void)?

    public override init() { super.init() }

    public func startObserving(onWillSleep: @escaping () -> Void,
                               onDidWake: @escaping () -> Void) {
        stop()
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(self, selector: #selector(systemWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        centre.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        onWillSleep = nil
        onDidWake = nil
    }

    @objc private func systemWillSleep() { onWillSleep?() }
    @objc private func systemDidWake() { onDidWake?() }

    /// Removing the observer touches main-actor state, so it cannot run on
    /// whatever thread releases this.
    isolated deinit { stop() }
}
#endif

#if DEBUG
public final class FakeSystemSleepObserver: SystemSleepObserving {
    private var wake: (() -> Void)?
    private var sleep: (() -> Void)?
    public private(set) var isObserving = false
    public init() {}
    public func startObserving(onWillSleep: @escaping () -> Void,
                               onDidWake: @escaping () -> Void) {
        sleep = onWillSleep; wake = onDidWake; isObserving = true
    }
    public func stop() { isObserving = false }
    /// The lid shutting on a screaming alarm.
    public func simulateWillSleep() { sleep?() }
    /// The Mac coming back afterwards.
    public func simulateWake() { wake?() }
}
#endif
