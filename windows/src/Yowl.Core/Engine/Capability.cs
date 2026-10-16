namespace Yowl.Core.Engine;

/// <summary>Anything that may be absent on a given machine.</summary>
public interface ICapability
{
    string Identifier { get; }

    /// <summary>
    /// Can this run on this machine? Fixed at construction: the engine filters on
    /// it once, so the user can never switch on something the machine lacks.
    /// </summary>
    bool IsAvailable { get; }

    /// <summary>
    /// Does the user want this one active? Re-read on every arm and every fire,
    /// because preferences change between alarms.
    /// </summary>
    bool IsEnabled { get; set; }
}

public static class CapabilityExtensions
{
    /// <summary>
    /// The only correct way to ask "will this actually run?". Combining the two
    /// axes at each call site is how the Mac app came to claim a feature was on
    /// for a build that had dropped it, so the combination lives here, once.
    /// </summary>
    public static bool IsActive(this ICapability capability) =>
        capability.IsAvailable && capability.IsEnabled;
}

/// <summary>Context handed to every response when the alarm fires.</summary>
public sealed record AlarmContext(TriggerId Trigger, DateTimeOffset FiredAt);

/// <summary>A condition that can start the alarm.</summary>
public interface ITrigger : ICapability
{
    TriggerId Id { get; }

    /// <summary>Time the user gets to disarm before the siren starts. Zero is immediate.</summary>
    TimeSpan Grace { get; set; }

    /// <summary>
    /// Whether this trigger could still fire if armed right now. An
    /// edge-detected trigger can be available and yet unable to fire because
    /// the edge it watches for has already passed: the charger is already out.
    /// Arming is refused when nothing can fire, so "Armed" always means protected.
    /// </summary>
    bool CanFireNow { get; }

    void Start(Action<TriggerId> onFire);
    void Stop();
}

/// <summary>
/// An action taken when the alarm fires. Must be idempotent: fire may be called
/// when already firing, and reset when it never fired.
/// </summary>
public interface IResponse : ICapability
{
    Task FireAsync(AlarmContext context);
    Task ResetAsync();
}
