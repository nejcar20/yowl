namespace Yowl.Core.Engine;

/// <summary>Stable identifier for a trigger, used in logs, alerts and the UI.</summary>
public readonly record struct TriggerId(string Value)
{
    public static readonly TriggerId Power = new("power");
    public static readonly TriggerId Motion = new("motion");

    public override string ToString() => Value;
}

public abstract record AlarmState
{
    public static readonly AlarmState Disarmed = new DisarmedState();
    public static readonly AlarmState Armed = new ArmedState();

    public sealed record DisarmedState : AlarmState;
    public sealed record ArmedState : AlarmState;
    /// <summary>A trigger fired but the user still has until <see cref="Until"/> to disarm.</summary>
    public sealed record Grace(DateTimeOffset Until, TriggerId Trigger) : AlarmState;
    public sealed record Firing(TriggerId Trigger) : AlarmState;

    public bool IsArmed => this is not DisarmedState;
    public bool IsFiring => this is Firing;
}

public abstract record AlarmEvent
{
    public static readonly AlarmEvent Arm = new ArmEvent();
    public static readonly AlarmEvent Disarm = new DisarmEvent();
    public static readonly AlarmEvent GraceExpired = new GraceExpiredEvent();

    public sealed record ArmEvent : AlarmEvent;
    public sealed record DisarmEvent : AlarmEvent;
    public sealed record Triggered(TriggerId Trigger, TimeSpan Grace) : AlarmEvent;
    public sealed record GraceExpiredEvent : AlarmEvent;
}

public static class AlarmReducer
{
    /// <summary>
    /// Pure transition function. No I/O and no ambient time: <paramref name="now"/>
    /// is passed in so grace deadlines are deterministic in tests.
    /// </summary>
    public static AlarmState Reduce(AlarmState state, AlarmEvent @event, DateTimeOffset now) =>
        (state, @event) switch
        {
            (_, AlarmEvent.DisarmEvent) => AlarmState.Disarmed,

            (AlarmState.DisarmedState or AlarmState.ArmedState, AlarmEvent.ArmEvent) => AlarmState.Armed,

            (AlarmState.ArmedState, AlarmEvent.Triggered t) => t.Grace > TimeSpan.Zero
                ? new AlarmState.Grace(now + t.Grace, t.Trigger)
                : new AlarmState.Firing(t.Trigger),

            (AlarmState.Grace g, AlarmEvent.GraceExpiredEvent) => new AlarmState.Firing(g.Trigger),

            // Everything else is a no-op: triggers while disarmed or already
            // firing, stale grace timers, re-arming mid-alarm.
            _ => state,
        };
}
