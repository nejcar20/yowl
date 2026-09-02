import Foundation

public protocol ScreenLocking: AnyObject {
    var isAvailable: Bool { get }
    func lock()
}

/// Wraps the private `SACLockScreenImmediate`. There is no public API for
/// locking the screen, so the App Store build will simply report
/// `isAvailable == false` and the engine will skip this response.
public final class LoginFrameworkScreenLocker: ScreenLocking {
    private typealias LockFn = @convention(c) () -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let symbol: LockFn?

    public init() {
        handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            RTLD_LAZY)
        if let handle, let sym = dlsym(handle, "SACLockScreenImmediate") {
            symbol = unsafeBitCast(sym, to: LockFn.self)
        } else {
            symbol = nil
        }
    }

    public var isAvailable: Bool { symbol != nil }

    public func lock() { _ = symbol?() }
}

#if DEBUG
// Test doubles are Debug-only. They are `public` so the test target and
// SwiftUI previews (both Debug builds) can reach them; shipping them in a
// Release build of a security product would export, among other things, an
// in-memory passcode store with a public accessor for the raw hash record.
public final class FakeScreenLocker: ScreenLocking {
    public let isAvailable: Bool
    public private(set) var lockCount = 0
    public init(isAvailable: Bool) { self.isAvailable = isAvailable }
    public func lock() { guard isAvailable else { return }; lockCount += 1 }
}
#endif  // DEBUG

/// Locks the screen so a thief cannot browse an open session while it screams.
/// Deliberately has no `reset`: there is nothing to undo. Unlocking the Mac is
/// NOT the disarm — the siren keeps sounding until the app's own passcode is
/// entered in the menu bar, so leaving the screen locked after a disarm is the
/// correct, and harmless, outcome.
public final class ScreenLockResponse: Response {
    public let identifier = "screen-lock"
    private let locker: ScreenLocking

    public init(locker: ScreenLocking) { self.locker = locker }

    public var isAvailable: Bool { locker.isAvailable }

    public func fire(context: AlarmContext) async {
        guard locker.isAvailable else { return }
        locker.lock()
    }

    public func reset() async {}
}
