namespace Yowl.Core.Security;

/// <summary>
/// Keeps the siren audible with the lid shut.
///
/// On Windows, closing the lid runs the power plan's "lid close action", which
/// is normally Sleep. While the siren sounds, the implementation switches that
/// action to "Do nothing" for a bounded time, then puts the user's setting back,
/// including from a watchdog process if Yowl itself is killed.
/// </summary>
public interface ILidSleepSuppressor
{
    /// <summary>Whether this machine has a lid whose action can be changed.</summary>
    bool IsAvailable { get; }

    /// <summary>Holds sleep off for at most <paramref name="duration"/>. False if refused.</summary>
    Task<bool> HoldAsync(TimeSpan duration);

    Task ReleaseAsync();

    /// <summary>
    /// Puts back a lid action left changed by a previous run that never got to
    /// release it. Called once at startup.
    /// </summary>
    void RecoverFromCrash();
}

public static class LidSleepLimits
{
    /// <summary>
    /// A minute of siren is enough to make someone put the machine down. A
    /// laptop that cannot sleep, shut in a bag with the camera running, is a
    /// fire risk, so the hold is bounded and short by default.
    /// </summary>
    public static readonly TimeSpan DefaultHold = TimeSpan.FromSeconds(60);

    public static readonly IReadOnlyList<TimeSpan> HoldChoices =
        [TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(5)];

    public static TimeSpan Clamp(TimeSpan value) =>
        value < HoldChoices[0] ? HoldChoices[0]
        : value > HoldChoices[^1] ? HoldChoices[^1]
        : value;

    public static string Label(TimeSpan hold) =>
        hold.TotalSeconds < 60 ? $"{(int)hold.TotalSeconds} seconds"
        : hold.TotalSeconds == 60 ? "1 minute"
        : $"{(int)hold.TotalMinutes} minutes";
}
