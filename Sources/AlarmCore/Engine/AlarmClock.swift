import Foundation

/// A unit of scheduled work that can be cancelled before it runs.
public protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Time and scheduling, injectable so grace periods are testable without waiting.
/// Named `AlarmClock` to avoid colliding with the standard library's `Clock`.
public protocol AlarmClock: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) -> ScheduledWork
}

/// Production clock backed by `DispatchQueue.main`.
public final class SystemClock: AlarmClock {
    public init() {}
    public var now: Date { Date() }

    private final class Work: ScheduledWork {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    @discardableResult
    public func schedule(after seconds: TimeInterval,
                         _ body: @escaping () -> Void) -> ScheduledWork {
        // ISOLATION INVARIANT (not checked by the compiler): `body` is a
        // main-actor-isolated closure — AlarmEngine's grace-expiry callback,
        // which reads and writes the engine's main-actor state — and it
        // converts to a `DispatchWorkItem` with no diagnostic, erasing that
        // isolation.
        //
        // It is safe *only* because the item is dispatched to `.main`. Change
        // this queue to a global or custom one and the grace timer starts
        // mutating AlarmEngine.state off the main actor, silently. If a
        // background queue is ever needed here, the body must be hopped back
        // (e.g. `Task { @MainActor in ... }`) rather than run in place.
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Work(item)
    }
}
