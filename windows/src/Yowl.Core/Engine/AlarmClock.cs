namespace Yowl.Core.Engine;

/// <summary>A unit of scheduled work that can be cancelled before it runs.</summary>
public interface IScheduledWork
{
    void Cancel();
}

/// <summary>
/// Time and scheduling, injectable so grace periods are testable without waiting.
///
/// Implementations must run scheduled work on the same thread as everything
/// else in the app (the UI thread on Windows). Nothing in Yowl.Core locks: the
/// engine, the triggers and the responses all assume one thread, exactly as the
/// Mac app assumes the main actor.
/// </summary>
public interface IAlarmClock
{
    DateTimeOffset Now { get; }
    IScheduledWork Schedule(TimeSpan after, Action body);
}
