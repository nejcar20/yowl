import Foundation

/// Manually advanced clock for tests. Not used in production code.
public final class TestClock: AlarmClock {
    private final class Work: ScheduledWork {
        let deadline: Date
        let body: () -> Void
        var cancelled = false
        init(deadline: Date, body: @escaping () -> Void) {
            self.deadline = deadline
            self.body = body
        }
        func cancel() { cancelled = true }
    }

    private var pending: [Work] = []
    public private(set) var now: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) { self.now = now }

    @discardableResult
    public func schedule(after seconds: TimeInterval,
                         _ body: @escaping () -> Void) -> ScheduledWork {
        let work = Work(deadline: now.addingTimeInterval(seconds), body: body)
        pending.append(work)
        return work
    }

    /// Moves time forward, running anything whose deadline has passed.
    public func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = pending.filter { !$0.cancelled && $0.deadline <= now }
        pending.removeAll { $0.cancelled || $0.deadline <= now }
        due.forEach { $0.body() }
    }
}
