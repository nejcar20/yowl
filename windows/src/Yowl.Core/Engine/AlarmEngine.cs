using Yowl.Core.Security;

namespace Yowl.Core.Engine;

public enum ArmRefusal
{
    /// <summary>No passcode and no screen lock: nothing could ever stop the siren.</summary>
    NoPasscodeSet,

    /// <summary>
    /// Every enabled trigger reported it cannot fire now, so arming would show a
    /// shield over zero protection. Refused rather than warned: "Armed" must
    /// mean protected.
    /// </summary>
    NoArmableTrigger,

    /// <summary>
    /// Triggers could have fired but none would start (a camera that will not
    /// open). Distinct from <see cref="NoArmableTrigger"/>, because telling the
    /// user to plug in the charger when the camera failed is exactly the
    /// confusion this exists to prevent.
    /// </summary>
    NoTriggerStarted,
}

public sealed class ArmRefusedException(ArmRefusal reason) : Exception(reason.ToString())
{
    public ArmRefusal Reason { get; } = reason;
}

/// <summary>Orchestrates triggers, responses and the state machine. Single-threaded.</summary>
public sealed class AlarmEngine
{
    private readonly IReadOnlyList<ITrigger> _triggers;
    private readonly IReadOnlyList<IResponse> _responses;
    private readonly IAlarmClock _clock;
    private readonly IPasscodeStore _passcodes;
    private readonly ISleepAssertion? _sleepAssertion;
    private IScheduledWork? _graceWork;
    private AlarmState _state = AlarmState.Disarmed;

    public AlarmEngine(IEnumerable<ITrigger> triggers,
                       IEnumerable<IResponse> responses,
                       IAlarmClock clock,
                       IPasscodeStore passcodes,
                       ISleepAssertion? sleepAssertion)
    {
        // Capability gating: unavailable features are dropped here, once.
        _triggers = triggers.Where(t => t.IsAvailable).ToList();
        _responses = responses.Where(r => r.IsAvailable).ToList();
        _clock = clock;
        _passcodes = passcodes;
        _sleepAssertion = sleepAssertion;
    }

    public AlarmState State
    {
        get => _state;
        private set
        {
            if (_state == value) return;
            _state = value;
            StateChanged?.Invoke(value);
        }
    }

    public event Action<AlarmState>? StateChanged;

    /// <summary>Raised after every response has fired for one alarm.</summary>
    public event Action? ResponsesFired;

    /// <summary>
    /// True when the last arm could not keep the machine awake. Arming is not
    /// blocked on this: a machine kept awake by other means is still protected,
    /// so a warning beats a refusal.
    /// </summary>
    public bool SleepAssertionFailed { get; private set; }

    /// <summary>Triggers the user enabled that would not start.</summary>
    public IReadOnlyList<string> FailedTriggers { get; private set; } = [];

    /// <summary>The most recent response run, so tests can await its side effects.</summary>
    internal Task PendingFire { get; private set; } = Task.CompletedTask;

    /// <summary>
    /// Unlocking the machine authenticates a disarm when the screen lock is
    /// doing its job, so this is also when a passcode stops being required.
    /// Re-read rather than captured, because the screen lock is a toggle.
    /// </summary>
    private bool ScreenLockWillFire =>
        _responses.Any(r => r.Identifier == Responses.ScreenLockResponse.Id && r.IsActive());

    public void Arm()
    {
        // Either authenticator will do. Neither means nothing can stop a siren.
        if (!_passcodes.HasPasscode && !ScreenLockWillFire)
            throw new ArmRefusedException(ArmRefusal.NoPasscodeSet);
        if (State != AlarmState.Disarmed) return;

        // Every check that can refuse runs before any side effect, so a failed
        // arm leaves nothing half-configured.
        var armable = _triggers.Where(t => t.IsActive() && t.CanFireNow).ToList();
        if (armable.Count == 0) throw new ArmRefusedException(ArmRefusal.NoArmableTrigger);

        SleepAssertionFailed = false;
        FailedTriggers = [];
        try { _sleepAssertion?.Acquire("Yowl armed"); }
        catch { SleepAssertionFailed = true; }

        // Armed before any trigger starts, so a trigger that calls back during
        // Start lands on a real Armed state rather than a Disarmed one the
        // reducer would silently ignore.
        State = AlarmReducer.Reduce(State, AlarmEvent.Arm, _clock.Now);

        var started = 0;
        var failed = new List<string>();
        foreach (var trigger in armable)
        {
            var grace = trigger.Grace;
            try
            {
                trigger.Start(id => HandleTrigger(id, grace));
                started++;
            }
            catch
            {
                failed.Add(trigger.Identifier);
            }
        }
        FailedTriggers = failed;

        if (started == 0)
        {
            // Nothing is watching. Undo and refuse rather than show a shield
            // over no protection.
            _sleepAssertion?.Release();
            SleepAssertionFailed = false;
            State = AlarmReducer.Reduce(State, AlarmEvent.Disarm, _clock.Now);
            throw new ArmRefusedException(ArmRefusal.NoTriggerStarted);
        }
    }

    public bool Disarm(string passcode)
    {
        if (!_passcodes.Verify(passcode)) return false;
        PerformDisarm();
        return true;
    }

    /// <summary>
    /// The owner unlocked Windows: stronger authentication than a short
    /// passcode, already performed. Accepted only while the screen lock will
    /// fire. Without it the siren sounds on a machine that was never locked, so
    /// an unlock proves nothing.
    /// </summary>
    public bool DisarmByScreenUnlock()
    {
        if (!ScreenLockWillFire || State == AlarmState.Disarmed) return false;
        PerformDisarm();
        return true;
    }

    private void PerformDisarm()
    {
        _graceWork?.Cancel();
        _graceWork = null;
        foreach (var trigger in _triggers) trigger.Stop();
        _sleepAssertion?.Release();
        SleepAssertionFailed = false;
        FailedTriggers = [];
        State = AlarmReducer.Reduce(State, AlarmEvent.Disarm, _clock.Now);
        _ = ResetResponsesAsync();
    }

    private async Task ResetResponsesAsync()
    {
        foreach (var response in _responses) await response.ResetAsync();
    }

    internal void HandleTrigger(TriggerId id, TimeSpan grace)
    {
        var next = AlarmReducer.Reduce(State, new AlarmEvent.Triggered(id, grace), _clock.Now);
        if (next == State) return;
        State = next;

        switch (next)
        {
            case AlarmState.Grace:
                _graceWork = _clock.Schedule(grace, GraceExpired);
                break;
            case AlarmState.Firing firing:
                FireResponses(firing.Trigger);
                break;
        }
    }

    private void GraceExpired()
    {
        var next = AlarmReducer.Reduce(State, AlarmEvent.GraceExpired, _clock.Now);
        if (next == State) return;
        State = next;
        if (next is AlarmState.Firing firing) FireResponses(firing.Trigger);
    }

    /// <summary>
    /// The machine slept mid-alarm and has come back. A thief who opens the lid
    /// should meet the siren again; an owner who already disarmed should meet
    /// silence. Safe to call on every wake: the state check is the whole guard.
    /// </summary>
    public void ResumeAfterWake()
    {
        if (State is AlarmState.Firing firing) FireResponses(firing.Trigger);
    }

    private void FireResponses(TriggerId trigger)
    {
        var context = new AlarmContext(trigger, _clock.Now);
        PendingFire = FireResponsesAsync(context);
    }

    private async Task FireResponsesAsync(AlarmContext context)
    {
        foreach (var response in _responses.Where(r => r.IsActive()))
        {
            // Re-checked before each one: a disarm can land while an earlier
            // response is awaiting, and a siren started after the reset would
            // scream with the UI showing "Arm" and no way to stop it.
            if (!State.IsFiring) return;
            await response.FireAsync(context);
        }
        if (State.IsFiring) ResponsesFired?.Invoke();
    }
}
