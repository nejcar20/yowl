using Yowl.Core.Engine;

namespace Yowl.Core.Responses;

public interface IScreenLocker
{
    bool IsAvailable { get; }
    void Lock();
}

/// <summary>
/// Locks Windows so a thief cannot browse an open session while it screams.
/// Nothing to undo on reset: leaving the session locked after a disarm is
/// harmless, and unlocking it is itself one way to disarm.
/// </summary>
public sealed class ScreenLockResponse(IScreenLocker locker) : IResponse
{
    public const string Id = "screen-lock";

    public string Identifier => Id;
    public bool IsAvailable => locker.IsAvailable;
    public bool IsEnabled { get; set; } = true;

    public Task FireAsync(AlarmContext context)
    {
        if (locker.IsAvailable) locker.Lock();
        return Task.CompletedTask;
    }

    public Task ResetAsync() => Task.CompletedTask;
}
