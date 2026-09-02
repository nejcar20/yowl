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
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Work(item)
    }
}
