import Foundation

/// Tells the app when the Mac has been unlocked, which is the event that
/// authenticates a disarm.
public protocol ScreenUnlockObserving: AnyObject {
    func startObserving(onUnlock: @escaping () -> Void)
    func stop()
}

/// Backed by the `com.apple.screenIsUnlocked` distributed notification.
///
/// This is a notification name, not a private API -- but it is delivered only to
/// apps outside the sandbox, which is one more reason the Mac App Store build of
/// this app was never going to work.
public final class DistributedScreenUnlockObserver: NSObject, ScreenUnlockObserving {
    private static let unlocked = Notification.Name("com.apple.screenIsUnlocked")
    private var onUnlock: (() -> Void)?

    public override init() { super.init() }

    /// Registered by selector, not with a closure: the closure-based API takes a
    /// `@Sendable` block, and capturing a main-actor callback in one is a
    /// data-race warning this package does not suppress.
    public func startObserving(onUnlock: @escaping () -> Void) {
        stop()
        self.onUnlock = onUnlock
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked), name: Self.unlocked, object: nil)
    }

    public func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        onUnlock = nil
    }

    @objc private func screenUnlocked() { onUnlock?() }

    /// Removing the observer touches main-actor state, so it cannot run on
    /// whatever thread releases this.
    isolated deinit { stop() }
}

#if DEBUG
public final class FakeScreenUnlockObserver: ScreenUnlockObserving {
    private var handler: (() -> Void)?
    public private(set) var isObserving = false
    public init() {}

    public func startObserving(onUnlock: @escaping () -> Void) {
        handler = onUnlock
        isObserving = true
    }

    public func stop() { isObserving = false }

    /// The user coming back and unlocking their Mac.
    public func simulateUnlock() { handler?() }
}
#endif
