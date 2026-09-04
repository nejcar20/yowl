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
public final class DistributedScreenUnlockObserver: ScreenUnlockObserving {
    private static let unlocked = Notification.Name("com.apple.screenIsUnlocked")
    private var token: (any NSObjectProtocol)?

    public init() {}

    public func startObserving(onUnlock: @escaping () -> Void) {
        stop()
        token = DistributedNotificationCenter.default().addObserver(
            forName: Self.unlocked, object: nil, queue: .main) { _ in
                onUnlock()
            }
    }

    public func stop() {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
        token = nil
    }

    /// The observer outlives no one: removing it in a plain `deinit` would touch
    /// main-actor state from whatever thread released this. See the package's
    /// standing rule against `@unchecked Sendable` -- `isolated deinit` is the
    /// sanctioned way to do this.
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
